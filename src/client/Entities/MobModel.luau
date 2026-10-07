--!strict
--[[
	How a mob is drawn on this client, pure (Entities/MobRenderer puts it on parts;
	tests/spec/MobsClient checks it): where it is between the server's updates, which way it
	faces, its colours, and what the crosshair hits.

	  Motion    the server sends a mob's state when it changed, every Config.Mobs.SyncTicks (0.1 s).
	            Each update starts a glide from where the mob is drawn now to the new position and
	            facing, over that interval (`apply`, `pose`), so it moves smoothly and stops where
	            the server has it; the facing turns the short way round. A jump of more than
	            SNAP_DISTANCE blocks (a teleport, a respawn in range) snaps.
	  Colours   each part's kind colour (a sheep's first part its fleece, `variant`); hurt (the
	            server's flash flag, 10 ticks) blends every part towards Minecraft's hurt red
	            (0.7 of the way, OverlayTexture's red overlay); a creeper with its fuse lit
	            flashes white, faster as the fuse burns (Creeper renderer's swelling flash: on
	            for the odd tenths of its 30 ticks); dying, it reddens and tips over on its side
	            over 20 ticks (LivingEntityRenderer's death rotation: 90 degrees x
	            sqrt(progress x 1.6), at most 90).
	  Aiming    `pick` is the nearest mob box on a ray (WAILA names it, a left click hits it), and
	            `near` lists the mobs around a point.

	Units are blocks and seconds; yaw in radians, facing (sin yaw, cos yaw).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MobList = require(Shared.Entities.MobList)

export type Mob = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	health: number,
	flags: number,
	fuse: number,
	-- The glide: from (fx, fy, fz, fyaw) at `startedAt` to (x, y, z, yaw) `duration` later.
	fx: number,
	fy: number,
	fz: number,
	fyaw: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	startedAt: number,
	duration: number,
	-- When it started dying (nil: alive).
	diedAt: number?,
}

export type State = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
	flags: number,
	fuse: number,
}

local MobModel = {}

MobModel.SNAP_DISTANCE = 8
-- Seconds a glide between updates takes (the server's sync interval).
MobModel.GLIDE = math.max(1, Config.Mobs.SyncTicks) / 20
-- Minecraft's hurt overlay: this share of the way to red.
MobModel.HURT_RED = 0.7
MobModel.HURT_COLOUR = { 255, 0, 0 }
MobModel.DEATH_SECONDS = 1
-- Flags (Protocol.MobFlag).
MobModel.HURT = 1
MobModel.BURNING = 2
MobModel.DYING = 4
MobModel.FUSE = 8

-- The yaw `from` turned towards `to` by `alpha` (0..1) the short way round.
function MobModel.lerpAngle(from: number, to: number, alpha: number): number
	local delta = (to - from + math.pi) % (2 * math.pi) - math.pi
	return from + delta * alpha
end

-- A new mob from its spawn (`now`: os.clock()).
function MobModel.new(id: number, kind: MobList.Kind, variant: number, state: State, now: number): Mob
	return {
		id = id,
		kind = kind,
		variant = variant,
		health = state.health,
		flags = state.flags,
		fuse = state.fuse,
		fx = state.x,
		fy = state.y,
		fz = state.z,
		fyaw = state.yaw,
		x = state.x,
		y = state.y,
		z = state.z,
		yaw = state.yaw,
		startedAt = now,
		duration = 0,
		diedAt = if bit32.btest(state.flags, MobModel.DYING) then now else nil,
	}
end

-- Where the mob is drawn at `now`: its feet (blocks) and yaw.
function MobModel.pose(mob: Mob, now: number): (number, number, number, number)
	if mob.duration <= 0 then
		return mob.x, mob.y, mob.z, mob.yaw
	end
	local alpha = math.clamp((now - mob.startedAt) / mob.duration, 0, 1)
	if alpha >= 1 then
		return mob.x, mob.y, mob.z, mob.yaw
	end
	return mob.fx + (mob.x - mob.fx) * alpha,
		mob.fy + (mob.y - mob.fy) * alpha,
		mob.fz + (mob.z - mob.fz) * alpha,
		MobModel.lerpAngle(mob.fyaw, mob.yaw, alpha)
end

-- A state update from the server at `now`: the glide to it starts from where the mob is drawn.
function MobModel.apply(mob: Mob, state: State, now: number)
	local x, y, z, yaw = MobModel.pose(mob, now)
	local dx, dy, dz = state.x - x, state.y - y, state.z - z
	if dx * dx + dy * dy + dz * dz > MobModel.SNAP_DISTANCE * MobModel.SNAP_DISTANCE then
		x, y, z, yaw = state.x, state.y, state.z, state.yaw
	end
	mob.fx, mob.fy, mob.fz, mob.fyaw = x, y, z, yaw
	mob.x, mob.y, mob.z, mob.yaw = state.x, state.y, state.z, state.yaw
	mob.startedAt = now
	mob.duration = MobModel.GLIDE
	mob.health = state.health
	mob.flags = state.flags
	mob.fuse = state.fuse
	if bit32.btest(state.flags, MobModel.DYING) then
		mob.diedAt = mob.diedAt or now
	else
		mob.diedAt = nil
	end
end

-- How far it has tipped over (radians about its facing's side axis) at `now`: 0 while alive.
function MobModel.tip(mob: Mob, now: number): number
	local died = mob.diedAt
	if died == nil then
		return 0
	end
	local progress = math.clamp((now - died) / MobModel.DEATH_SECONDS, 0, 1)
	return math.rad(math.min(90, math.sqrt(progress * 1.6) * 90))
end

-- Is a creeper's white flash on at `now` (its fuse lit, `fuse` ticks of 30 burnt)?
function MobModel.flashing(mob: Mob, now: number): boolean
	if not bit32.btest(mob.flags, MobModel.FUSE) or mob.fuse <= 0 then
		return false
	end
	local fuse = mob.kind.fuse
	local total = if fuse then fuse.ticks else 30
	-- (Faster as it burns: Minecraft flips every tenth of the swell.)
	local rate = 4 + 12 * math.clamp(mob.fuse / total, 0, 1)
	return math.floor(now * rate) % 2 == 1
end

--[[
	The colour (0..255 each) of the mob's part `index` at `now`: its kind's (a sheep's fleece in
	its variant), white while a creeper flashes, blended towards red while hurt or dying.
]]
function MobModel.colour(mob: Mob, index: number, now: number): (number, number, number)
	local base = if index == 1 then MobList.variantColor(mob.kind, mob.variant) else mob.kind.parts[index].color
	local r, g, b = base[1], base[2], base[3]
	if MobModel.flashing(mob, now) then
		r, g, b = 255, 255, 255
	end
	if bit32.btest(mob.flags, MobModel.HURT) or mob.diedAt ~= nil then
		local red, share = MobModel.HURT_COLOUR, MobModel.HURT_RED
		r, g, b = r + (red[1] - r) * share, g + (red[2] - g) * share, b + (red[3] - b) * share
	end
	return r, g, b
end

function MobModel.burning(mob: Mob): boolean
	return bit32.btest(mob.flags, MobModel.BURNING)
end

-- Where the ray from (ox, oy, oz) along the unit (dx, dy, dz) enters the box, nil when it misses
-- (0 when it starts inside).
local function rayBox(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): number?
	local near, far = -math.huge, math.huge
	local function slab(o: number, d: number, lo: number, hi: number): boolean
		if math.abs(d) < 1e-12 then
			return o >= lo and o <= hi
		end
		local t1, t2 = (lo - o) / d, (hi - o) / d
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		near, far = math.max(near, t1), math.min(far, t2)
		return near <= far
	end
	if not (slab(ox, dx, minX, maxX) and slab(oy, dy, minY, maxY) and slab(oz, dz, minZ, maxZ)) then
		return nil
	end
	if far < 0 then
		return nil
	end
	return math.max(near, 0)
end
MobModel.rayBox = rayBox

--[[
	The nearest live mob of `mobs` whose box (drawn at `now`) the ray from (ox, oy, oz) along the
	unit (dx, dy, dz) enters within `maxDistance`, and how far along the ray. Dying mobs are not
	aimed at.
]]
function MobModel.pick(
	mobs: { [number]: Mob },
	now: number,
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	maxDistance: number
): (Mob?, number)
	local best: Mob? = nil
	local bestDistance = maxDistance
	for _, mob in mobs do
		if mob.diedAt == nil then
			local x, y, z = MobModel.pose(mob, now)
			local half = mob.kind.width / 2
			local t = rayBox(ox, oy, oz, dx, dy, dz, x - half, y, z - half, x + half, y + mob.kind.height, z + half)
			if t and t <= bestDistance then
				best, bestDistance = mob, t
			end
		end
	end
	return best, bestDistance
end

return MobModel
