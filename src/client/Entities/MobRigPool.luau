--!strict
--!native
--[[
	Which mobs are drawn how, and the parts that draw them, pure (Entities/MobParts gives it real
	Parts and moves them, for Entities/MobRenderer and the Studio probe; tests/spec/MobRigPool
	gives it tables). Every frame `frame` works out where each mob is drawn, which tier it gets,
	poses the rigs (Entities/MobRig) and lists the parts to move with their frames, so the
	renderer only turns numbers into CFrames and calls BulkMoveTo once.

	  Tiers     (Config.Mobs.Rig) by distance from the listener (Audio/SoundPlayer: the camera,
	            kept near the player's eyes, so zooming out doesn't strip the zombies round the
	            player down to boxes):
	              full      the 15-part R15 body and the look's extras (at most 17 parts) within
	                        FullDistance (16 blocks), the nearest MaxFull (16) at most; posed every
	                        frame
	              reduced   (at most 8 parts) to ReducedDistance (40), and full-tier candidates past
	                        MaxFull; posed every REDUCED_EVERY frames (staggered by the id), placed
	                        from its last pose in between. REDUCED_EVERY is 1: posed every other
	                        frame, a reduced rig's limbs moved up to 0.53 studs on one frame and
	                        none on the next, against the 0.3 a frame continuity budget, and posing
	                        them every frame costs about 0.03 ms native and 0.15 ms interpreted for
	                        24 rigs (tests/spec/MobRigPool's cost test); 2 is a fallback for a slow
	                        phone (tools/probes/README.md)
	              impostor  the kind's two boxes (MobList `parts`) beyond, or past MaxRigs (40)
	                        rigs; every other kind (cows, sheep...) always
	            A mob changes tier only Hysteresis (4) blocks past a threshold (out at 20 and 44,
	            in at 16 and 40), and holds its place under the caps over a newcomer up to
	            Hysteresis blocks nearer, so mobs at an edge don't flicker between tiers. So at
	            most 16 x 17 + 24 x 8 = 464 rig parts move a frame.
	  Pools     rigs are kept whole per tier when a mob leaves the tier or the game: SpareFull
	            (12) full and SpareReduced (16) reduced rigs, SPARE_IMPOSTOR impostors; parts are
	            re-sized (another kind's scale, another look's extras) and re-coloured (only where
	            the colour differs) on reuse, unused slots parked out of the scene. Releases run
	            before acquisitions each frame, so once warm no part is created or destroyed while
	            the zombies round a player come and go.
	  Colours   Entities/ZombieLooks, worked out once a mob; the hurt red (MobModel.reddened)
	            repaints a rig once when it starts and once when it ends.
	  Flames    a burning mob's flames (MobRenderer's Fire, `flames`) ride on the part its tier burns
	            on (MobRig.FIRE_SLOT: the upper torso, the reduced torso, the first box). The pool
	            moves them (`attach`) whenever that part changes, and takes them off a rig before
	            it lets the rig go: a released rig's parts may be destroyed (its tier's spares are
	            full), and destroying a part destroys what hangs on it, so the flames are never on
	            a part that goes. Their lifetime is the renderer's.
	  Factory   { create(sx, sy, sz, colour, shadow) -> part (made out of the scene), resize(part,
	            sx, sy, sz), paint(part, colour), park(part), show(part), destroy(part),
	            attach(flames, part or nil) }: studs and packed 0xRRGGBB colours.

	The frame's output: `parts[1..count]` and `matrices` (12 numbers a part, CFrame.new's order,
	render studs), `fullRigs` and `reducedRigs`, and the live zombies nearest first
	(`zombieIds`, `zombieDistances`, `zombies`) for Entities/ZombieVoices.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local MobModel = require(script.Parent.MobModel)
local MobRig = require(script.Parent.MobRig)
local ZombieLooks = require(script.Parent.ZombieLooks)

local BLOCK = Config.BlockSize
local FULL, REDUCED, IMPOSTOR = MobRig.FULL, MobRig.REDUCED, MobRig.IMPOSTOR

local MobRigPool = {}

-- Spare impostors kept (two parts each; the old renderer kept 128 parts).
MobRigPool.SPARE_IMPOSTOR = 64
-- Frames between a reduced rig's poses (see the header).
MobRigPool.REDUCED_EVERY = 1
-- Slots of a rig by tier.
MobRigPool.SLOTS = table.freeze({ MobRig.FULL_SLOTS, MobRig.REDUCED_SLOTS, MobRig.IMPOSTOR_SLOTS })

export type Settings = {
	MaxRigs: number,
	MaxFull: number,
	FullDistance: number,
	ReducedDistance: number,
	Hysteresis: number,
	SpareFull: number,
	SpareReduced: number,
}

export type Factory<P> = {
	create: (sx: number, sy: number, sz: number, colour: number, shadow: boolean) -> P,
	resize: (part: P, sx: number, sy: number, sz: number) -> (),
	paint: (part: P, colour: number) -> (),
	park: (part: P) -> (),
	show: (part: P) -> (),
	destroy: (part: P) -> (),
	attach: (flames: any, part: P?) -> (),
}

export type Rig<P> = {
	tier: number,
	parts: { P },
	-- Per slot: in the scene, and the colour last painted.
	shown: { boolean },
	painted: { number },
	-- The shape its parts are sized for.
	shape: MobRig.Shape,
}

export type Entry<P> = {
	mob: MobModel.Mob,
	build: MobRig.Build,
	paint: ZombieLooks.Paint,
	-- Drawn as a rig when near (a kind with a rig); else always the impostor.
	rigged: boolean,
	zombie: boolean,
	rig: Rig<P>?,
	-- The last pose (MobRig.pose), relative to the base, and the tier it was posed for (0: none).
	rel: { number },
	posedTier: number,
	-- Painted reddened (hurt or dying).
	red: boolean,
	-- Its flames while it burns (the renderer's), and the part they hang on (nil: none yet).
	flames: any,
	flamesOn: P?,
	-- This frame: where it is drawn (blocks, feet), its yaw, distance, wanted tier and ranking key.
	x: number,
	y: number,
	z: number,
	yaw: number,
	distance: number,
	want: number,
	key: number,
}

export type Pool<P> = {
	factory: Factory<P>,
	settings: Settings,
	entries: { [number]: Entry<P> },
	-- Every entry, nearest first as of the last frame.
	order: { Entry<P> },
	spare: { { Rig<P> } },
	-- Parts made and destroyed so far.
	created: number,
	destroyed: number,
	frames: number,
	-- The frame's output.
	parts: { P },
	matrices: { number },
	count: number,
	fullRigs: number,
	reducedRigs: number,
	zombieIds: { number },
	zombieDistances: { number },
	zombies: number,
	-- Scratch.
	candidates: { Entry<P> },
	fulls: { Entry<P> },
}

function MobRigPool.new<P>(factory: Factory<P>, settings: Settings?): Pool<P>
	return {
		factory = factory,
		settings = settings or Config.Mobs.Rig,
		entries = {},
		order = {},
		spare = { {}, {}, {} },
		created = 0,
		destroyed = 0,
		frames = 0,
		parts = {},
		matrices = {},
		count = 0,
		fullRigs = 0,
		reducedRigs = 0,
		zombieIds = {},
		zombieDistances = {},
		zombies = 0,
		candidates = {},
		fulls = {},
	}
end

local function spareCap<P>(pool: Pool<P>, tier: number): number
	local s = pool.settings
	return if tier == FULL then s.SpareFull elseif tier == REDUCED then s.SpareReduced else MobRigPool.SPARE_IMPOSTOR
end

-- Parks a rig's parts and keeps it for reuse (or destroys it when the tier's spares are full).
local function release<P>(pool: Pool<P>, rig: Rig<P>)
	local factory = pool.factory
	local shown = rig.shown
	for slot, part in rig.parts do
		if shown[slot] then
			factory.park(part)
			shown[slot] = false
		end
	end
	local spare = pool.spare[rig.tier]
	if #spare < spareCap(pool, rig.tier) then
		table.insert(spare, rig)
	else
		for _, part in rig.parts do
			factory.destroy(part)
		end
		pool.destroyed += #rig.parts
	end
end

-- Paints the rig's shown slots with `colours` (reddened when `red`), where they differ.
local function repaint<P>(pool: Pool<P>, rig: Rig<P>, colours: { number }, red: boolean)
	local factory = pool.factory
	local painted, shown, parts = rig.painted, rig.shown, rig.parts
	for slot = 1, rig.shape.count do
		if shown[slot] then
			local colour = colours[slot] or 0
			if red then
				colour = ZombieLooks.hurt(colour)
			end
			if painted[slot] ~= colour then
				painted[slot] = colour
				factory.paint(parts[slot], colour)
			end
		end
	end
end

-- Gives the entry a rig of its wanted tier: a spare one re-sized, or a new one.
local function acquire<P>(pool: Pool<P>, entry: Entry<P>)
	local tier = entry.want
	local shape = MobRig.shape(entry.build, tier)
	local factory = pool.factory
	local colours = ZombieLooks.of(entry.paint, tier)
	local rig = table.remove(pool.spare[tier])
	if rig == nil then
		local slots = MobRigPool.SLOTS[tier]
		local parts = table.create(slots)
		local painted = table.create(slots, -1)
		for slot = 1, slots do
			local k = slot * 3
			local used = slot <= shape.count
			local colour = if used then colours[slot] or 0 else 0
			local shadow = if tier == IMPOSTOR then true else slot <= shape.body and shape.shadow[slot]
			parts[slot] = factory.create(
				if used then shape.size[k - 2] else 1,
				if used then shape.size[k - 1] else 1,
				if used then shape.size[k] else 1,
				colour,
				shadow
			)
			painted[slot] = colour
		end
		pool.created += slots
		rig = { tier = tier, parts = parts, shown = table.create(slots, false), painted = painted, shape = shape }
	end
	local r = rig :: Rig<P>
	if r.shape ~= shape then
		local size = shape.size
		for slot = 1, shape.count do
			local k = slot * 3
			factory.resize(r.parts[slot], size[k - 2], size[k - 1], size[k])
		end
		r.shape = shape
	end
	local shown, hidden = r.shown, shape.hidden
	for slot, part in r.parts do
		local visible = slot <= shape.count and not hidden[slot]
		if visible ~= shown[slot] then
			shown[slot] = visible
			if visible then
				factory.show(part)
			else
				factory.park(part)
			end
		end
	end
	repaint(pool, r, colours, entry.red)
	entry.rig = r
	entry.posedTier = 0
end

-- Sorts list[1..n] by `key` (insertion: nearly sorted already).
local function sortByKey<P>(list: { Entry<P> }, n: number)
	for i = 2, n do
		local e = list[i]
		local key = e.key
		local j = i - 1
		while j >= 1 and list[j].key > key do
			list[j + 1] = list[j]
			j -= 1
		end
		list[j + 1] = e
	end
end

-- Each entry's tier this frame (see the header); `order` is nearest first.
local function choose<P>(pool: Pool<P>)
	local s = pool.settings
	local hysteresis = s.Hysteresis
	local order, candidates, fulls = pool.order, pool.candidates, pool.fulls
	local n = 0
	for _, e in order do
		if not e.rigged then
			e.want = IMPOSTOR
			continue
		end
		local d = e.distance
		local rig = e.rig
		local current = if rig then rig.tier else IMPOSTOR
		local want = IMPOSTOR
		if d <= s.FullDistance or (current == FULL and d <= s.FullDistance + hysteresis) then
			want = FULL
		elseif d <= s.ReducedDistance or (current ~= IMPOSTOR and d <= s.ReducedDistance + hysteresis) then
			want = REDUCED
		end
		e.want = want
		if want ~= IMPOSTOR then
			n += 1
			candidates[n] = e
			e.key = if current ~= IMPOSTOR then d - hysteresis else d
		end
	end
	for i = n + 1, #candidates do
		candidates[i] = nil
	end
	sortByKey(candidates, n)
	local rigs = math.min(n, s.MaxRigs)
	for i = rigs + 1, n do
		candidates[i].want = IMPOSTOR
	end
	local f = 0
	for i = 1, rigs do
		local e = candidates[i]
		if e.want == FULL then
			f += 1
			fulls[f] = e
			local rig = e.rig
			e.key = if rig and rig.tier == FULL then e.distance - hysteresis else e.distance
		end
	end
	for i = f + 1, #fulls do
		fulls[i] = nil
	end
	sortByKey(fulls, f)
	for i = s.MaxFull + 1, f do
		fulls[i].want = REDUCED
	end
	pool.fullRigs = math.min(f, s.MaxFull)
	pool.reducedRigs = rigs - pool.fullRigs
end

-- Takes the entry's flames off the part they hang on (before its rig goes).
local function unhook<P>(pool: Pool<P>, entry: Entry<P>)
	if entry.flamesOn ~= nil then
		pool.factory.attach(entry.flames, nil)
		entry.flamesOn = nil
	end
end

-- A mob the server spawned (MobModel.new); replaces one with the same id.
function MobRigPool.add<P>(pool: Pool<P>, mob: MobModel.Mob): Entry<P>
	MobRigPool.remove(pool, mob.id)
	local kind = mob.kind
	local entry: Entry<P> = {
		mob = mob,
		build = MobRig.build(kind, mob.variant),
		paint = ZombieLooks.paint(kind, mob.variant, mob.id),
		rigged = kind.rig ~= nil,
		zombie = kind.zombie == true,
		rig = nil,
		rel = table.create(12 * (if kind.rig then MobRig.FULL_SLOTS else MobRig.IMPOSTOR_SLOTS), 0),
		posedTier = 0,
		red = MobModel.reddened(mob),
		flames = nil,
		flamesOn = nil,
		x = mob.x,
		y = mob.y,
		z = mob.z,
		yaw = mob.yaw,
		distance = math.huge,
		want = IMPOSTOR,
		key = math.huge,
	}
	pool.entries[mob.id] = entry
	table.insert(pool.order, entry)
	return entry
end

-- A mob gone: its rig goes back to its pool.
function MobRigPool.remove<P>(pool: Pool<P>, id: number)
	local entry = pool.entries[id]
	if entry == nil then
		return
	end
	pool.entries[id] = nil
	local index = table.find(pool.order, entry)
	if index then
		table.remove(pool.order, index)
	end
	unhook(pool, entry)
	entry.flames = nil
	local rig = entry.rig
	if rig then
		release(pool, rig)
		entry.rig = nil
	end
end

-- The part a burning mob's flames sit on (its upper torso, torso or first box), nil before its
-- first frame.
function MobRigPool.anchor<P>(entry: Entry<P>): P?
	local rig = entry.rig
	if rig == nil then
		return nil
	end
	return rig.parts[MobRig.FIRE_SLOT[rig.tier]]
end

--[[
	Gives mob `id` its flames (nil: none, it stopped burning): from the next frame they hang on
	the part its tier burns on (see the header). Old flames are taken off first; making and
	destroying them is the caller's.
]]
function MobRigPool.setFlames<P>(pool: Pool<P>, id: number, flames: any)
	local entry = pool.entries[id]
	if entry == nil or entry.flames == flames then
		return
	end
	unhook(pool, entry)
	entry.flames = flames
end

--[[
	One frame at `now`: strides, tiers, rigs, poses, and this frame's parts and frames (see the
	header). (lx, ly, lz): the listener in blocks; (originX, originZ): the floating origin in
	studs (Shared/World/Origin), taken off the frames.
]]
function MobRigPool.frame<P>(
	pool: Pool<P>,
	now: number,
	lx: number,
	ly: number,
	lz: number,
	originX: number,
	originZ: number
)
	pool.frames += 1
	local order = pool.order
	local n = #order
	-- Where each mob is drawn, its stride, its distance and its hurt red.
	for i = 1, n do
		local e = order[i]
		local mob = e.mob
		local x, y, z, yaw = MobModel.pose(mob, now)
		e.x, e.y, e.z, e.yaw = x, y, z, yaw
		if e.rigged then
			MobModel.stride(mob, now)
		end
		local dx, dy, dz = x - lx, y + mob.kind.height * 0.5 - ly, z - lz
		e.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	-- Nearest first (insertion: the order barely changes from one frame to the next).
	for i = 2, n do
		local e = order[i]
		local d = e.distance
		local j = i - 1
		while j >= 1 and order[j].distance > d do
			order[j + 1] = order[j]
			j -= 1
		end
		order[j + 1] = e
	end
	choose(pool)
	-- Rigs: every release before any acquisition, so a rig let go this frame serves another.
	for i = 1, n do
		local e = order[i]
		local rig = e.rig
		if rig and rig.tier ~= e.want then
			unhook(pool, e)
			release(pool, rig)
			e.rig = nil
		end
	end
	local voices = 0
	local zombieIds, zombieDistances = pool.zombieIds, pool.zombieDistances
	for i = 1, n do
		local e = order[i]
		local mob = e.mob
		local red = MobModel.reddened(mob)
		local rig = e.rig
		if rig == nil then
			e.red = red
			acquire(pool, e)
		elseif red ~= e.red then
			e.red = red
			repaint(pool, rig, ZombieLooks.of(e.paint, rig.tier), red)
		end
		if e.zombie and mob.diedAt == nil then
			voices += 1
			zombieIds[voices] = mob.id
			zombieDistances[voices] = e.distance
		end
		local flames = e.flames
		if flames ~= nil then
			local r = e.rig :: Rig<P>
			local anchor = r.parts[MobRig.FIRE_SLOT[r.tier]]
			if e.flamesOn ~= anchor then
				pool.factory.attach(flames, anchor)
				e.flamesOn = anchor
			end
		end
	end
	for i = voices + 1, pool.zombies do
		zombieIds[i] = nil
		zombieDistances[i] = nil
	end
	pool.zombies = voices
	-- Poses and frames.
	local parts, matrices = pool.parts, pool.matrices
	local frame = pool.frames
	local every = MobRigPool.REDUCED_EVERY
	local count, at = 0, 0
	for i = 1, n do
		local e = order[i]
		local rig = e.rig :: Rig<P>
		local tier = rig.tier
		local shape = rig.shape
		local mob = e.mob
		if tier == FULL or e.posedTier ~= tier or (tier == REDUCED and (frame + mob.id) % every == 0) then
			MobRig.pose(e.rel, e.build, shape, mob, now)
			e.posedTier = tier
		end
		local tip = MobModel.tip(mob, now)
		local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = MobRig.base(
			e.x * BLOCK - originX,
			e.y * BLOCK,
			e.z * BLOCK - originZ,
			e.yaw,
			tip,
			mob.kind.width * 0.5 * BLOCK
		)
		at = MobRig.place(matrices, at, e.rel, shape, bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22)
		local rigParts, hidden = rig.parts, shape.hidden
		for slot = 1, shape.count do
			if not hidden[slot] then
				count += 1
				parts[count] = rigParts[slot]
			end
		end
	end
	for i = count + 1, pool.count do
		parts[i] = nil
	end
	pool.count = count
end

-- Every mob gone (their rigs back in the pools), and nothing left to draw.
function MobRigPool.clear<P>(pool: Pool<P>)
	for id in pool.entries do
		MobRigPool.remove(pool, id)
	end
	table.clear(pool.parts)
	table.clear(pool.zombieIds)
	table.clear(pool.zombieDistances)
	pool.count, pool.zombies, pool.fullRigs, pool.reducedRigs = 0, 0, 0, 0
end

return MobRigPool
