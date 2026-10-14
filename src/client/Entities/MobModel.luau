--!strict
--[[
	How a mob is drawn on this client, pure (Entities/MobRenderer puts it on parts;
	tests/spec/MobsClient checks it): where it is between the server's updates, which way it
	faces, how its legs move, its colours, and what the crosshair hits.

	  Motion    the server sends a mob's state when it changed, every Config.Mobs.SyncTicks (0.1 s;
	            a mob more than 32 blocks off every other sync). Each update starts a glide from
	            where the mob is drawn now to the new position and facing (`apply`, `pose`), so it
	            moves smoothly and stops where the server has it; the facing turns the short way
	            round. The glide lasts GLIDE, or the time since the last update when moving updates
	            come regularly slower than that (this update and the one before both moved the mob,
	            and this interval and the one before are both 1.5 to 3.5 GLIDE: the far mobs' half
	            rate), so a far zombie walks on instead of stopping between its updates. A near mob
	            that stood still a sync or two (the server sends only what changed), or stood turning
	            or changing its flags every other sync, then walks off: its glide stays GLIDE, so it
	            walks at its own speed rather than creeping, then rushing to catch up. A jump of more
	            than SNAP_DISTANCE blocks (a teleport, a respawn in range) snaps.
	  Moves     a move (Protocol op 6) carries the change from the position last decoded for the
	            mob (its spawn, state or move: `bx`, `by`, `bz`, the baseline); positions are whole
	            steps of 1/32 block, exact in a double, so the sum never drifts from the server's.
	  Stride    (`stride`, every frame, for the R15 rigs: Entities/MobRig) Minecraft's
	            WalkAnimationState: `walk` eases 0.4 of the way a tick (1 - 0.6^(dt x 20), whatever
	            the frame rate) towards min(speed x 4, 1), speed in blocks a tick from the glide
	            (held 2.5 glides after its start, so the gap before the next update doesn't stop the
	            legs), and `phase` (limbSwing) advances by `walk` a tick. Three blends move at a
	            steady BLEND_RATE (the whole way in a quarter second) towards the server's flags, so
	            a pose never jumps when one changes: `aggro` (Aggressive: it has a target or hunts),
	            `hammer` (Breaking: it hits a block) and `shriek` (Screaming). An Attack flag's
	            rising edge starts a swing (`swingStart`, SWING seconds long), unless the last
	            one is still going. (`limbs` and `limbsAt` are Entities/MobRig's: where its arms
	            and legs were last posed, so they never move faster than MobRig.LIMB_SPEED.)
	  Colours   each part's kind colour (a sheep's first part its fleece, a zombie's its look's
	            shirt: `variant`); hurt (the server's flash flag, 10 ticks) blends every part
	            towards Minecraft's hurt red (0.7 of the way, OverlayTexture's red overlay);
	            dying, it reddens and tips over on its side
	            over 20 ticks (LivingEntityRenderer's death rotation: 90 degrees x
	            sqrt(progress x 1.6), at most 90). (A zombie's rig is coloured by
	            Entities/ZombieLooks once, at spawn.)
	  Aiming    `pick` is the nearest mob box on a ray (WAILA names it, a left click hits it), and
	            `near` lists the mobs around a point.

	Units are blocks and seconds; yaw in radians, facing (sin yaw, cos yaw).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local Hash = require(Shared.Util.Hash)

export type Mob = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	health: number,
	flags: number,
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
	-- When the last update came (spawn, state or move), how long after the one before it (inf:
	-- none before), and whether it moved the mob (not only turned it or changed its flags).
	updatedAt: number,
	interval: number,
	moved: boolean,
	-- The op 6 baseline: the position last decoded for this mob (whole 1/32 steps).
	bx: number,
	by: number,
	bz: number,
	-- When it started dying (nil: alive).
	diedAt: number?,
	-- The stride (`stride`): how much it walks (0..1), the limb swing's position, and when the
	-- stride last ran.
	walk: number,
	phase: number,
	strideAt: number,
	-- Blends towards the Aggressive, Breaking and Screaming flags (0..1).
	aggro: number,
	hammer: number,
	shriek: number,
	-- When the last swing (the Attack flag's rising edge) started (-inf: none).
	swingStart: number,
	-- (Entities/MobRig) the limbs' last posed angles, 3 a limb (the upper joint's pitch and
	-- roll, the lower joint's bend: left arm, right arm, left leg, right leg), then the waist's
	-- pitch and roll; and when (-inf: never).
	limbs: { number },
	limbsAt: number,
	-- 0..1 from the id: a zombie's own head tilt and twitch timing.
	seed: number,
}

export type State = {
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
	flags: number,
}

local MobModel = {}

MobModel.SNAP_DISTANCE = 8
-- Seconds a glide between updates takes (the server's sync interval).
MobModel.GLIDE = math.max(1, Config.Mobs.SyncTicks) / 20
-- Moving updates this many glides apart (and no further apart than the second), twice running,
-- stretch the glide to their interval: the server sends far mobs every other sync.
MobModel.SLOW_UPDATES = { 1.5, 3.5 }
-- The glide's speed counts for the stride this many glides after the glide started.
MobModel.STRIDE_HOLD = 2.5
-- Minecraft's hurt overlay: this share of the way to red.
MobModel.HURT_RED = 0.7
MobModel.HURT_COLOUR = { 255, 0, 0 }
MobModel.DEATH_SECONDS = 1
-- Seconds an attack swing takes (Entities/MobRig draws it).
MobModel.SWING = 0.35
-- Flags (Protocol.MobFlag).
MobModel.HURT = Protocol.MobFlag.Hurt
MobModel.BURNING = Protocol.MobFlag.Burning
MobModel.DYING = Protocol.MobFlag.Dying
MobModel.AGGRESSIVE = Protocol.MobFlag.Aggressive
MobModel.ATTACK = Protocol.MobFlag.Attack
MobModel.BREAKING = Protocol.MobFlag.Breaking
MobModel.SCREAMING = Protocol.MobFlag.Screaming
-- The stride's easing a tick (WalkAnimationState: 0.4 of the way), and how fast the flag blends
-- move (the whole way in 1 / BLEND_RATE seconds, at a steady pace: no limb ever whips round).
MobModel.WALK_KEEP = 0.6
MobModel.BLEND_RATE = 4
-- Seconds of the longest frame the stride steps over (a hitch doesn't fling the legs).
MobModel.MAX_STEP = 0.25

-- The yaw `from` turned towards `to` by `alpha` (0..1) the short way round.
function MobModel.lerpAngle(from: number, to: number, alpha: number): number
	local delta = (to - from + math.pi) % (2 * math.pi) - math.pi
	return from + delta * alpha
end

-- A new mob from its spawn (`now`: os.clock()).
function MobModel.new(id: number, kind: MobList.Kind, variant: number, state: State, now: number): Mob
	local flags = state.flags
	return {
		id = id,
		kind = kind,
		variant = variant,
		health = state.health,
		flags = flags,
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
		updatedAt = now,
		interval = math.huge,
		moved = false,
		bx = state.x,
		by = state.y,
		bz = state.z,
		diedAt = if bit32.btest(flags, MobModel.DYING) then now else nil,
		walk = 0,
		phase = 0,
		strideAt = now,
		aggro = if bit32.btest(flags, MobModel.AGGRESSIVE) then 1 else 0,
		hammer = if bit32.btest(flags, MobModel.BREAKING) then 1 else 0,
		shriek = if bit32.btest(flags, MobModel.SCREAMING) then 1 else 0,
		swingStart = -math.huge,
		limbs = table.create(14, 0),
		limbsAt = -math.huge,
		seed = Hash.hash2(id % 4294967296, 0x2F15, 0x51) / 4294967296,
	}
end

-- Where the mob is drawn at `now`: its feet (blocks) and yaw.
function MobModel.pose(mob: Mob, now: number): (number, number, number, number)
	if mob.duration <= 0 then
		return mob.x, mob.y, mob.z, mob.yaw
	end
	local alpha = (now - mob.startedAt) / mob.duration
	if alpha >= 1 then
		return mob.x, mob.y, mob.z, mob.yaw
	elseif alpha < 0 then
		alpha = 0
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
	local interval, before = now - mob.updatedAt, mob.interval
	local moved = state.x ~= mob.x or state.y ~= mob.y or state.z ~= mob.z
	local slowest, fastest = MobModel.GLIDE * MobModel.SLOW_UPDATES[2], MobModel.GLIDE * MobModel.SLOW_UPDATES[1]
	local regular = moved
		and mob.moved
		and interval >= fastest
		and interval <= slowest
		and before >= fastest
		and before <= slowest
	mob.fx, mob.fy, mob.fz, mob.fyaw = x, y, z, yaw
	mob.x, mob.y, mob.z, mob.yaw = state.x, state.y, state.z, state.yaw
	mob.bx, mob.by, mob.bz = state.x, state.y, state.z
	mob.startedAt = now
	mob.updatedAt = now
	mob.interval = interval
	mob.moved = moved
	mob.duration = if regular then interval else MobModel.GLIDE
	mob.health = state.health
	if
		bit32.btest(state.flags, MobModel.ATTACK)
		and not bit32.btest(mob.flags, MobModel.ATTACK)
		and now - mob.swingStart >= MobModel.SWING
	then
		mob.swingStart = now
	end
	mob.flags = state.flags
	if bit32.btest(state.flags, MobModel.DYING) then
		mob.diedAt = mob.diedAt or now
	else
		mob.diedAt = nil
	end
end

--[[
	A move (Protocol op 6) at `now`: the change (dx, dy, dz blocks) from the baseline, the
	position last decoded for the mob, then as `apply`.
]]
function MobModel.move(
	mob: Mob,
	dx: number,
	dy: number,
	dz: number,
	yaw: number,
	health: number,
	flags: number,
	now: number
)
	MobModel.apply(
		mob,
		{ x = mob.bx + dx, y = mob.by + dy, z = mob.bz + dz, yaw = yaw, health = health, flags = flags },
		now
	)
end

-- `value` moved towards `target` by at most `step`.
local function approach(value: number, target: number, step: number): number
	if value < target then
		return math.min(value + step, target)
	end
	return math.max(value - step, target)
end

--[[
	Advances the stride and the flag blends to `now` (once a frame, for a mob drawn with a rig):
	see the header. The speed is the glide's, in blocks a tick.
]]
function MobModel.stride(mob: Mob, now: number)
	local dt = now - mob.strideAt
	mob.strideAt = now
	if dt <= 0 then
		return
	elseif dt > MobModel.MAX_STEP then
		dt = MobModel.MAX_STEP
	end
	local ticks = dt * 20
	local speed = 0
	local duration = mob.duration
	if duration > 0 and mob.diedAt == nil and now - mob.startedAt < duration * MobModel.STRIDE_HOLD then
		local dx, dz = mob.x - mob.fx, mob.z - mob.fz
		speed = math.sqrt(dx * dx + dz * dz) / (duration * 20)
	end
	local target = speed * 4
	if target > 1 then
		target = 1
	end
	local walk = mob.walk + (target - mob.walk) * (1 - MobModel.WALK_KEEP ^ ticks)
	mob.walk = walk
	mob.phase += walk * ticks
	local step = MobModel.BLEND_RATE * dt
	local flags = mob.flags
	mob.aggro = approach(mob.aggro, if bit32.btest(flags, MobModel.AGGRESSIVE) then 1 else 0, step)
	mob.hammer = approach(mob.hammer, if bit32.btest(flags, MobModel.BREAKING) then 1 else 0, step)
	mob.shriek = approach(mob.shriek, if bit32.btest(flags, MobModel.SCREAMING) then 1 else 0, step)
end

-- Is the mob drawn reddened now (the hurt flash, or dying)?
function MobModel.reddened(mob: Mob): boolean
	return mob.diedAt ~= nil or bit32.btest(mob.flags, MobModel.HURT)
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

--[[
	The colour (0..255 each) of the mob's part `index` at `now`: its kind's (a sheep's fleece or
	a zombie's shirt in its variant), blended towards red while hurt or dying.
]]
function MobModel.colour(mob: Mob, index: number, _now: number): (number, number, number)
	local base = if index == 1 then MobList.variantColor(mob.kind, mob.variant) else mob.kind.parts[index].color
	local r, g, b = base[1], base[2], base[3]
	if MobModel.reddened(mob) then
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
