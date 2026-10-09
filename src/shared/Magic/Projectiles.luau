--!strict
--[[
	Magic projectiles (ItemList `magic.projectile`: Terraria's Wand of Sparking, gem staves and
	Water Bolt), shared and pure, so the server (Players/Magic: the authority, its hits hurt mobs)
	and every client (Rendering/ProjectileView: what is drawn) fly the same path from the same
	start. The server only says where one starts (Net/MagicSync spawn), where it went after a
	bounce (sync) and where it ended (end); nothing is sent while it flies, as items in
	transporters.

	Kinds, by index (MagicSync carries the index, append only):
	  1 spark  1.0 blocks a tick, gravity 0.03 and drag 0.99 a tick (Minecraft's arrow order: move,
	           then drag, then gravity), 20 ticks: an arc of about 18 blocks fired level, ending
	           on the first block or mob (Terraria's Wand of Sparking: 7 px a tick, about 23
	           tiles, 50% On Fire!: the item's `fire`, server).
	  2 bolt   1.5 blocks a tick straight, 20 ticks (30 blocks), ends on a block or a mob
	           (Terraria's gem staves).
	  3 water  0.6 blocks a tick straight, 60 ticks (36 blocks), bounces off blocks BOUNCES 5
	           times (the velocity's component across the face hit turns round) and ends at the
	           next, and goes through one mob to hit a second (Terraria's Water Bolt: bounces,
	           pierces).
	A tick (`step`), with `getBlock` the side's blocks (server world:peekBlock; client the
	ClientWorld; nil = not loaded: passes) and `targets` the mobs near (their feet, width, height):
	  1. the segment from the position along the velocity is cast against blocks
	     (World/VoxelRaycast; blocks with a collision box stop it: Blocks.obstruction, a lantern's
	     outline, never plants, torches or fluids) and against every mob box not struck before,
	     grown by MOB_MARGIN 0.3 (Minecraft's ProjectileUtil inflates them so) with a slab test;
	  2. mobs before the block are struck nearest first (`hits` lists them for the caller) until
	     the kind's `hits` run out: it ends at the last one;
	  3. a block ends it, or bounces it (water): it stops at the face, BOUNCE_GAP off it, the rest
	     of the tick's travel dropped;
	  4. otherwise it moves the whole segment; then drag and gravity; after `life` moves it
	     expires.
	The returned event says what the caller tells the clients: nil (flying), "bounce" (a sync),
	"block", "mob" or "expired" (an end; `reason` is MagicSync.Reason's). Determinism: the start
	is rounded to f32 (`new`), as the spawn op carries it, and every step is the same double
	arithmetic on both sides, so with the same blocks client and server fly the same path; mobs
	differ (a client draws them a little behind), so a client's own end is only what it shows.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Items = require(script.Parent.Parent.Items)
local MagicSync = require(script.Parent.Parent.Net.MagicSync)
local VoxelRaycast = require(script.Parent.Parent.World.VoxelRaycast)

export type Kind = {
	name: string,
	-- Blocks a tick at launch.
	speed: number,
	-- Taken off vy each tick, and the share of velocity kept each tick.
	gravity: number,
	drag: number,
	-- Ticks it flies at most.
	life: number,
	-- Blocks it bounces off before one ends it (0: the first ends it).
	bounces: number,
	-- Mobs it hits; it ends at the last.
	hits: number,
	-- Drawn (Rendering/ProjectileView): its colour, size (blocks) and light's range (blocks).
	color: { number },
	size: number,
	light: number,
}

-- A projectile in flight (world blocks, blocks a tick).
export type Projectile = {
	kind: number,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	-- Ticks flown, blocks bounced off, mobs hit (and which: their ids).
	age: number,
	bounces: number,
	hits: number,
	struck: { [number]: boolean },
	dead: boolean,
	-- Why it ended (MagicSync.Reason; only once dead).
	reason: number,
}

-- A mob it may hit: its id, feet (blocks) and box.
export type Target = { id: number, x: number, y: number, z: number, width: number, height: number }

export type Event = "bounce" | "block" | "mob" | "expired"

local Projectiles = {}

-- Mob boxes are grown by this (blocks) for the hit test.
Projectiles.MOB_MARGIN = 0.3
-- A bounce leaves the projectile this far off the face (blocks).
Projectiles.BOUNCE_GAP = 1e-3

Projectiles.KINDS = table.freeze({
	table.freeze({
		name = "spark",
		speed = 1,
		gravity = 0.03,
		drag = 0.99,
		life = 20,
		bounces = 0,
		hits = 1,
		color = { 255, 150, 50 },
		size = 0.2,
		light = 8,
	}),
	table.freeze({
		name = "bolt",
		speed = 1.5,
		gravity = 0,
		drag = 1,
		life = 20,
		bounces = 0,
		hits = 1,
		color = { 90, 255, 140 },
		size = 0.3,
		light = 10,
	}),
	table.freeze({
		name = "water",
		speed = 0.6,
		gravity = 0,
		drag = 1,
		life = 60,
		bounces = 5,
		hits = 2,
		color = { 80, 160, 255 },
		size = 0.4,
		light = 8,
	}),
} :: { Kind })
Projectiles.COUNT = #Projectiles.KINDS

local byName: { [string]: number } = {}
for index, kind in Projectiles.KINDS do
	assert(kind.speed <= MagicSync.MAX_SPEED, `Projectile {kind.name} is faster than MagicSync.MAX_SPEED`)
	byName[kind.name] = index
end
-- Every magic weapon casts a kind there is (ItemList `magic.projectile`).
for _, def in Items.list do
	local magic = def.magic
	if magic then
		assert(byName[magic.projectile], `Item {def.name} casts an unknown projectile {magic.projectile}`)
	end
end

-- The index of the kind named `name` (nil: none).
function Projectiles.kind(name: string): number?
	return byName[name]
end

-- The kind at `index` (nil: none).
function Projectiles.get(index: number): Kind?
	return Projectiles.KINDS[index]
end

-- (f32 rounding without allocating: what a spawn or sync op carries.)
local f32 = buffer.create(4)
local function round(value: number): number
	buffer.writef32(f32, 0, value)
	return buffer.readf32(f32, 0)
end

--[[
	A projectile of kind `kind` at (x, y, z) with velocity (vx, vy, vz) (blocks a tick), rounded
	to f32 as the wire carries it (so the spawn op starts every client where the server starts).
]]
function Projectiles.new(kind: number, x: number, y: number, z: number, vx: number, vy: number, vz: number): Projectile
	assert(Projectiles.KINDS[kind], `unknown projectile kind {kind}`)
	return {
		kind = kind,
		x = round(x),
		y = round(y),
		z = round(z),
		vx = round(vx),
		vy = round(vy),
		vz = round(vz),
		age = 0,
		bounces = 0,
		hits = 0,
		struck = {},
		dead = false,
		reason = MagicSync.Reason.Expired,
	}
end

-- A projectile of `kind` cast from (x, y, z) towards (dx, dy, dz) (any length) at the kind's speed.
function Projectiles.launch(
	kind: number,
	x: number,
	y: number,
	z: number,
	dx: number,
	dy: number,
	dz: number
): Projectile
	local def = Projectiles.KINDS[kind]
	assert(def, `unknown projectile kind {kind}`)
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if not (length > 1e-9) then
		dx, dy, dz, length = 0, 0, 1, 1
	end
	local speed = def.speed / length
	return Projectiles.new(kind, x, y, z, dx * speed, dy * speed, dz * speed)
end

-- Rounds where it is now to f32 (after a bounce, before the sync op says so).
function Projectiles.round(p: Projectile)
	p.x, p.y, p.z = round(p.x), round(p.y), round(p.z)
	p.vx, p.vy, p.vz = round(p.vx), round(p.vy), round(p.vz)
end

-- Puts the projectile where an op says (a sync: f32 numbers already).
function Projectiles.place(p: Projectile, x: number, y: number, z: number, vx: number, vy: number, vz: number)
	p.x, p.y, p.z, p.vx, p.vy, p.vz = x, y, z, vx, vy, vz
end

--[[ A tick ]]

local function stops(block: number): boolean
	return Blocks.obstruction(block) ~= nil
end

-- A solid block fills its cell (the ray's own cell test); a lantern only its outline.
local function wallBox(block: number, _x: number, _y: number, _z: number): { number }?
	if Blocks.isSolid(block) then
		return nil
	end
	return Blocks.obstruction(block)
end

-- Where the ray o + t d crosses the slab lo..hi: entry and exit (nil when parallel and outside).
local function slab(o: number, d: number, lo: number, hi: number): (number?, number)
	if math.abs(d) < 1e-12 then
		if o < lo or o > hi then
			return nil, 0
		end
		return -math.huge, math.huge
	end
	local t1, t2 = (lo - o) / d, (hi - o) / d
	if t1 > t2 then
		return t2, t1
	end
	return t1, t2
end

-- How far along the unit ray from (ox, oy, oz) it enters target's grown box (0 inside; nil: misses).
local function enterTarget(
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
	target: Target
): number?
	local half = target.width / 2 + Projectiles.MOB_MARGIN
	local nearX, farX = slab(ox, dx, target.x - half, target.x + half)
	local nearY, farY =
		slab(oy, dy, target.y - Projectiles.MOB_MARGIN, target.y + target.height + Projectiles.MOB_MARGIN)
	local nearZ, farZ = slab(oz, dz, target.z - half, target.z + half)
	if nearX == nil or nearY == nil or nearZ == nil then
		return nil
	end
	local near = math.max(nearX, nearY, nearZ)
	local far = math.min(farX, farY, farZ)
	if near > far or far < 0 then
		return nil
	end
	return math.max(near, 0)
end

local function finish(p: Projectile, reason: number)
	p.dead = true
	p.reason = reason
end

--[[
	Flies `p` one tick (see the header) against `getBlock` and `targets` (nil: no mobs); the mobs
	it struck this tick are put in `hits` (cleared first; nil: not wanted). Returns what happened
	(nil: it flies on).
]]
function Projectiles.step(
	p: Projectile,
	getBlock: (x: number, y: number, z: number) -> number?,
	targets: { Target }?,
	hits: { Target }?
): Event?
	if hits then
		table.clear(hits)
	end
	if p.dead then
		return nil
	end
	local kind = Projectiles.KINDS[p.kind]
	local vx, vy, vz = p.vx, p.vy, p.vz
	local length = math.sqrt(vx * vx + vy * vy + vz * vz)
	local event: Event? = nil
	if length > 1e-9 then
		local dx, dy, dz = vx / length, vy / length, vz / length
		local wall = VoxelRaycast.cast(p.x, p.y, p.z, vx, vy, vz, length, getBlock, stops, wallBox)
		local limit = if wall then wall.distance else length
		-- Mobs before the wall, nearest first, while it has hits left.
		if targets then
			while p.hits < kind.hits do
				local best: Target? = nil
				local bestT = limit
				for _, target in targets do
					if not p.struck[target.id] then
						local t = enterTarget(p.x, p.y, p.z, dx, dy, dz, target)
						if t and t <= bestT then
							best, bestT = target, t
						end
					end
				end
				if best == nil then
					break
				end
				p.struck[best.id] = true
				p.hits += 1
				if hits then
					table.insert(hits, best)
				end
				if p.hits >= kind.hits then
					p.x, p.y, p.z = p.x + dx * bestT, p.y + dy * bestT, p.z + dz * bestT
					finish(p, MagicSync.Reason.Mob)
					return "mob"
				end
			end
		end
		if wall then
			local t = wall.distance
			local nx, ny, nz = wall.nx, wall.ny, wall.nz
			p.x = p.x + dx * t + nx * Projectiles.BOUNCE_GAP
			p.y = p.y + dy * t + ny * Projectiles.BOUNCE_GAP
			p.z = p.z + dz * t + nz * Projectiles.BOUNCE_GAP
			if p.bounces >= kind.bounces or (nx == 0 and ny == 0 and nz == 0) then
				-- (No face: it started inside the block.)
				finish(p, MagicSync.Reason.Block)
				return "block"
			end
			p.bounces += 1
			if nx ~= 0 then
				vx = -vx
			elseif ny ~= 0 then
				vy = -vy
			else
				vz = -vz
			end
			event = "bounce"
		else
			p.x, p.y, p.z = p.x + vx, p.y + vy, p.z + vz
		end
	end
	p.vx, p.vy, p.vz = vx * kind.drag, vy * kind.drag - kind.gravity, vz * kind.drag
	p.age += 1
	if p.age >= kind.life then
		finish(p, MagicSync.Reason.Expired)
		return "expired"
	end
	return event
end

return Projectiles
