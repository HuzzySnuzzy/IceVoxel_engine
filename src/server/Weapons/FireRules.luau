--!strict
--[[
	The rules of a shot on the server, pure (Weapons/Firing plays them out; tests/spec/WeaponFiring
	runs them on fake players and blocks). Nothing here touches Roblox: a shooter is a snapshot
	(Shooter), mobs and players are candidates (MobCandidate, PlayerCandidate), blocks a `getBlock`.

	  Checks   a Fire message (Net/WeaponSync.Fire) from a shooter, in this order; the first that
	           fails is the reason (REASONS):
	             rate       more than Config.Weapons.ShotsPerSecond a second (bursts of twice
	                        that): `take` on the shooter's bucket, Weapons/Firing's own step (it
	                        drops such a shot silently, after acknowledging it)
	             disabled   Config.Weapons.Enabled is false
	             spectator  a spectator (Shared/GameMode)
	             dead       no living character
	             slot       the message's hotbar slot is not the selected one
	             item       the hand doesn't hold the item the message names
	             weapon     that item is no firearm (Shared/Weapons)
	             raise      not raised (Inventory/Types.AIM_ATTRIBUTE, set by Weapons/WeaponActions
	                        from the client's Weapon messages), raised in another hotbar slot or
	                        with another item (a raise never carries over, not even before
	                        WeaponActions' next look), or raised less than Config.Weapons.RaiseTicks
	                        ago (one tick of slack for the two clocks)
	             busy       a reload, a round, a jam or a fire mode being seen to (WeaponActions'
	                        lock; one tick of slack)
	             cadence    sooner after the last than the fire mode's shot time (Shared/Weapons/
	                        Handling.ready: one tick of slack, at most half a shot)
	             origin     the claimed eyes more than OriginSlack from the server's, a block
	                        (Shared/Blocks/Shapes.sight's collision boxes) between the two, or an
	                        aim further than DirectionSlack from a unit vector
	             ruined, jammed, empty   Shared/Weapons/WeaponState.canFire of the held gun
	                        (creative fires without a round, never a Ruined or jammed gun)
	  Flight   `shotSpec`: the round's velocity, range and falloff with the gun's zero and damage
	           scale, Config.Weapons' gravity, longest flight and segment; `directions`: the
	           shot's spread (Handling.spread of the message's stance and the muzzle device) and
	           each pellet's cone (Shared/Weapons/Ballistics.pellets); `round`: the round fired (the
	           chambered one; creative with none: the calibre's first round).
	  Targets  `mobTarget`: a mob's boxes (Ballistics.mobBoxes: where it is drawn), whether it is a
	           zombie and wears a helmet, hard hat or fire helmet (its look: Shared/Entities/
	           MobList.look), and where the shooter's client last saw it (lag compensation) when
	           that is within LagCompMax of where it is; `playerTarget`: a player's boxes at their
	           pose-aware eyes (the body box rising beside the head: `crown`). `blockRules`:
	           glass (ShatterBlocks by name, shattered only when ShatterGlass and the shooter may
	           build), leaves (names ending "Leaves", passed with PassLeaves).
	  Damage   `tally`: each pellet's last impact; every pellet on one target summed, the head's
	           share (Ballistics.damage: the head factor per pellet) apart from the body's (the
	           server hurts a head through no armour, Mobs/Mobs.weaponDamage, or only the helmet's,
	           Players/Characters.weaponHurt); the panes of glass passed, each once. `knockback`: a
	           bullet's BulletKnockback, PelletKnockback for each pellet that hit (at most
	           MAX_PELLET_KNOCKBACK).
	  Noise    `impactNoise`: where the infected hear a shot land (Config.Weapons.ImpactNoise): the
	           farthest last impact on anything at least that far from the shooter. The shot's own
	           noise is Handling.noise.
	  Shots    `record`: the Shots message's record of an accepted shot (each pellet's last impact,
	           Net/WeaponSync.Hit; clamped to the coordinates the message may carry, so a flight
	           off the edge of the world never spoils a message), `refused`: the shooter's record
	           of a refused one (no pellets; "jammed" sets its jam flag); `audience`: the shooter
	           and every listener within ShotBroadcast blocks (horizontally) of the muzzle.
	  Bolts    `recovery`: a round that `recover`s (the crossbow's bolt) drops again as an item
	           with chance BoltRecover where it stopped in a block (backed out 0.2 blocks along its
	           path), half that where it hit a mob or a player (at the hit); nothing where its flight
	           just ended.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Shapes = require(Shared.Blocks.Shapes)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)
local WeaponState = require(Shared.Weapons.WeaponState)
local Handling = require(Shared.Weapons.Handling)
local Ballistics = require(Shared.Weapons.Ballistics)

type Stack = Items.Stack
type GetBlock = (x: number, y: number, z: number) -> number?

export type Settings = Ballistics.Settings

-- A token bucket (`take`): tokens left and when it was last taken from (seconds).
export type Bucket = { tokens: number, last: number? }

-- What the checks read of the shooter (the server's view of them; times in seconds).
export type Shooter = {
	now: number,
	-- Shared/GameMode's mode.
	mode: string,
	alive: boolean,
	-- The selected hotbar slot (1..9) and the stack in it (nil: an empty hand).
	selected: number,
	held: Stack?,
	-- Inventory/Types.AIM_ATTRIBUTE's value, when the gun was raised, and the hotbar slot and item it
	-- was raised with (Weapons/WeaponActions.raised).
	aim: string?,
	raisedAt: number?,
	raisedSlot: number?,
	raisedItem: number?,
	-- When a weapon action's lock ends (nil: none).
	busyUntil: number?,
	-- When the last shot counts from (Handling.after; nil: none yet).
	lastShot: number?,
	-- The server's eyes (eyeX nil: no position).
	eyeX: number?,
	eyeY: number,
	eyeZ: number,
}

-- A live mob near a shot (server Mobs/Mobs.WeaponTarget's fields): sx, sy, sz where the
-- shooter's client was last sent it (nil: never).
export type MobCandidate = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	sx: number?,
	sy: number?,
	sz: number?,
}

-- A player who may be hit by a shot or hear it: feet, pose-aware eyes' height, alive, game mode.
export type PlayerCandidate = {
	key: any,
	x: number,
	y: number,
	z: number,
	eyeY: number,
	alive: boolean,
	mode: string,
}

-- Everything one shot's pellets did to one target: half hearts on the head and on the body
-- (before armour), and how many pellets hit it.
export type Hit = { target: Ballistics.Target, head: number, body: number, pellets: number }

-- A shot's pellets summed (`tally`).
export type Tally = {
	-- The mobs and players hit, in the order first hit.
	mobs: { Hit },
	players: { Hit },
	-- The cells of the panes of glass passed ({ x, y, z }, each once).
	glass: { { number } },
	-- Each pellet's last impact.
	finals: { Ballistics.Impact },
}

local FireRules = {}

-- The refusal reasons, in the order they are checked (see the header).
FireRules.REASONS = table.freeze({
	"rate",
	"disabled",
	"spectator",
	"dead",
	"slot",
	"item",
	"weapon",
	"raise",
	"busy",
	"cadence",
	"origin",
	"ruined",
	"jammed",
	"empty",
})
-- The most knockback a shot's pellets give one target (blocks a tick).
FireRules.MAX_PELLET_KNOCKBACK = 0.4
-- How far a recovered bolt is backed out of the block it stopped in (blocks).
FireRules.BOLT_BACK = 0.2

local TICK = Handling.TICK
-- The coordinates a Shots message may carry (Net/WeaponSync): horizontally, and up or down.
local LIMIT = Protocol.MAX_COORDINATE + 64
local Y_LIMIT = 4096

--[[ Rate ]]

-- A full bucket of `burst` tokens.
function FireRules.newBucket(burst: number): Bucket
	return { tokens = burst, last = nil }
end

-- Takes a token at `now` (seconds) from a bucket refilled at `rate` a second up to `burst`: false
-- when there is none.
function FireRules.take(bucket: Bucket, now: number, rate: number, burst: number): boolean
	local last = bucket.last
	if last ~= nil and now > last then
		bucket.tokens = math.min(burst, bucket.tokens + (now - last) * rate)
	end
	bucket.last = now
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

--[[ Checks ]]

-- Is a block (Shapes.sight's collision boxes) between (ax, ay, az) and (bx, by, bz)?
function FireRules.wallBetween(
	getBlock: GetBlock,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number
): boolean
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	if distance < 1e-6 then
		return false
	end
	local isTarget, outline = Shapes.sight(getBlock)
	local hit = VoxelRaycast.cast(ax, ay, az, dx, dy, dz, distance, getBlock, isTarget, outline)
	return hit ~= nil and hit.distance < distance - 1e-6
end

-- Do the claimed eyes and aim pass (see the header's origin)?
function FireRules.origin(shooter: Shooter, fire: WeaponSync.Fire, getBlock: GetBlock, s: Settings): boolean
	local ex = shooter.eyeX
	if ex == nil then
		return false
	end
	local ey, ez = shooter.eyeY, shooter.eyeZ
	local dx, dy, dz = fire.ox - ex, fire.oy - ey, fire.oz - ez
	if dx * dx + dy * dy + dz * dz > s.OriginSlack * s.OriginSlack then
		return false
	end
	local length = math.sqrt(fire.dx * fire.dx + fire.dy * fire.dy + fire.dz * fire.dz)
	if not (math.abs(length - 1) <= s.DirectionSlack) then
		return false
	end
	return not FireRules.wallBetween(getBlock, ex, ey, ez, fire.ox, fire.oy, fire.oz)
end

--[[
	Why the shot `fire` from `shooter` is refused (see the header: REASONS but "rate", which is
	Firing's), nil when it may go.
]]
function FireRules.check(shooter: Shooter, fire: WeaponSync.Fire, getBlock: GetBlock, s: Settings): string?
	if not s.Enabled then
		return "disabled"
	elseif GameMode.isSpectator(shooter.mode) then
		return "spectator"
	elseif not shooter.alive then
		return "dead"
	elseif fire.slot ~= shooter.selected then
		return "slot"
	end
	local held = shooter.held
	if held == nil or held.count < 1 or held.item ~= fire.item then
		return "item"
	end
	local spec = Weapons.firearm(held.item)
	if spec == nil then
		return "weapon"
	end
	local now = shooter.now
	local raisedAt = shooter.raisedAt
	if
		shooter.aim ~= Types.AIM_RAISED
		or raisedAt == nil
		or shooter.raisedSlot ~= shooter.selected
		or shooter.raisedItem ~= held.item
		or now - raisedAt < (s.RaiseTicks - Handling.SLACK_TICKS) * TICK - 1e-9
	then
		return "raise"
	end
	local busy = shooter.busyUntil
	if busy ~= nil and now < busy - Handling.SLACK_TICKS * TICK then
		return "busy"
	end
	if not Handling.ready(shooter.lastShot, now, Handling.shotTicks(spec, WeaponState.modeIndex(held))) then
		return "cadence"
	end
	if not FireRules.origin(shooter, fire, getBlock, s) then
		return "origin"
	end
	local ok, why = WeaponState.canFire(held, GameMode.instabuild(shooter.mode))
	if not ok then
		return why or "weapon"
	end
	return nil
end

--[[ The flight ]]

-- A flight of `ammo` fired from `spec` (see the header); `shooter` is never hit by it.
function FireRules.shotSpec(
	spec: Weapons.FirearmSpec,
	ammo: Weapons.AmmoSpec,
	s: Settings,
	shooter: any?
): Ballistics.ShotSpec
	return {
		velocity = ammo.velocity,
		gravity = s.Gravity,
		zero = spec.zero,
		range = ammo.range,
		maxRange = math.min(ammo.range * 2.5, s.MaxRange),
		falloffMin = ammo.falloffMin,
		damage = ammo.damage * spec.damageScale,
		segment = s.SegmentSeconds,
		shooter = shooter,
	}
end

-- The round a gun as it was before a shot (`before`) fired: its chambered one; in creative with
-- none, the first round of its calibre. nil: none.
function FireRules.round(before: Stack, spec: Weapons.FirearmSpec, creative: boolean): number?
	local chambered = WeaponState.chamber(before)
	if chambered ~= nil then
		return chambered
	elseif creative then
		return Weapons.ammoFor(spec.calibre)[1]
	end
	return nil
end

--[[
	The pellets' directions of a shot (see the header): the message's aim spread by the gun's cone
	for its stance and muzzle device (`muzzle`, `fraction` of it left), then each pellet's cone.
]]
function FireRules.directions(
	spec: Weapons.FirearmSpec,
	ammo: Weapons.AmmoSpec,
	fire: WeaponSync.Fire,
	muzzle: number?,
	fraction: number?,
	random: () -> number
): { Ballistics.Vec }
	local length = math.sqrt(fire.dx * fire.dx + fire.dy * fire.dy + fire.dz * fire.dz)
	if length < 1e-9 then
		length = 1
	end
	local cone = Handling.spread(spec, fire, muzzle, fraction)
	return Ballistics.pellets(
		fire.dx / length,
		fire.dy / length,
		fire.dz / length,
		cone,
		ammo.cone,
		ammo.pellets,
		random
	)
end

--[[ Targets ]]

-- Does a mob of `kind` in `variant` wear a helmet, a hard hat or a fire helmet?
function FireRules.helmet(kind: MobList.Kind, variant: number): boolean
	local look = MobList.look(kind, variant)
	local hat = if look then look.hat else nil
	return hat ~= nil and (hat.kind == "helmet" or hat.kind == "hardhat" or hat.kind == "firehelmet")
end

-- A mob as a shot's target (see the header).
function FireRules.mobTarget(mob: MobCandidate, s: Settings): Ballistics.Target
	local body, head = Ballistics.mobBoxes(mob.kind, mob.x, mob.y, mob.z, mob.yaw)
	local target: Ballistics.Target = {
		kind = "mob",
		key = mob.id,
		body = body,
		head = head,
		zombie = MobList.isZombie(mob.kind),
		helmet = FireRules.helmet(mob.kind, mob.variant),
	}
	local sx, sy, sz = mob.sx, mob.sy, mob.sz
	if sx ~= nil and sy ~= nil and sz ~= nil then
		local dx, dy, dz = sx - mob.x, sy - mob.y, sz - mob.z
		local apart = dx * dx + dy * dy + dz * dz
		if apart > 1e-12 and apart <= s.LagCompMax * s.LagCompMax then
			target.seenBody, target.seenHead = Ballistics.mobBoxes(mob.kind, sx, sy, sz, mob.yaw)
		end
	end
	return target
end

-- A player as a shot's target: their feet and pose-aware eyes' height.
function FireRules.playerTarget(key: any, fx: number, fy: number, fz: number, eyeY: number): Ballistics.Target
	local body, head = Ballistics.playerBoxes(fx, fy, fz, eyeY)
	return { kind = "player", key = key, body = body, head = head, crown = true }
end

-- (Block lookups: 1 per block id.)
local leavesLut = buffer.create(Blocks.count)
for id, def in Blocks.defs do
	if string.sub(def.name, -6) == "Leaves" then
		buffer.writeu8(leavesLut, id, 1)
	end
end

local function isLeaves(block: number): boolean
	return block >= 0 and block < Blocks.count and buffer.readu8(leavesLut, block) == 1
end

local function never(_block: number): boolean
	return false
end

-- What blocks do to a shot of a shooter who may (`mayBuild`) or may not break blocks (see the
-- header).
function FireRules.blockRules(s: Settings, mayBuild: boolean): Ballistics.BlockRules
	local glass: { [number]: boolean } = {}
	for _, name in s.ShatterBlocks do
		local id = rawget(Blocks.id :: any, name)
		if type(id) == "number" then
			glass[id] = true
		end
	end
	return {
		isGlass = function(block: number): boolean
			return glass[block] == true
		end,
		shatter = s.ShatterGlass and mayBuild,
		passes = if s.PassLeaves then isLeaves else never,
		glassShare = s.GlassShare,
	}
end

--[[ Damage ]]

-- Every pellet's impacts (Ballistics.trace each) summed (see the header).
function FireRules.tally(traces: { { Ballistics.Impact } }, shot: Ballistics.ShotSpec, s: Settings): Tally
	local tally: Tally = { mobs = {}, players = {}, glass = {}, finals = {} }
	local mobs: { [any]: Hit } = {}
	local players: { [any]: Hit } = {}
	local panes: { [string]: boolean } = {}
	for _, impacts in traces do
		for _, impact in impacts do
			local cell = impact.cell
			if impact.kind == "glass" and cell then
				local key = `{cell[1]},{cell[2]},{cell[3]}`
				if not panes[key] then
					panes[key] = true
					table.insert(tally.glass, cell)
				end
			end
		end
		local final = impacts[#impacts]
		if final == nil then
			continue
		end
		table.insert(tally.finals, final)
		local target = final.target
		if target == nil or (final.kind ~= "mob" and final.kind ~= "player") then
			continue
		end
		local byKey = if final.kind == "mob" then mobs else players
		local hit = byKey[target.key]
		if hit == nil then
			hit = { target = target, head = 0, body = 0, pellets = 0 }
			byKey[target.key] = hit
			table.insert(if final.kind == "mob" then tally.mobs else tally.players, hit)
		end
		local amount = Ballistics.damage(shot, final, s)
		if final.head then
			hit.head += amount
		else
			hit.body += amount
		end
		hit.pellets += 1
	end
	return tally
end

-- The knockback (blocks a tick) a target takes from `hits` of a shot's `pellets` pellets.
function FireRules.knockback(hits: number, pellets: number, s: Settings): number
	if pellets <= 1 then
		return s.BulletKnockback
	end
	return math.min(hits * s.PelletKnockback, FireRules.MAX_PELLET_KNOCKBACK)
end

--[[ Noise ]]

-- Where the infected hear a shot from (ox, oy, oz) land (see the header), nil when nowhere.
function FireRules.impactNoise(
	finals: { Ballistics.Impact },
	ox: number,
	oy: number,
	oz: number,
	s: Settings
): (number?, number, number)
	local least = s.ImpactNoise * s.ImpactNoise
	local best, bx, by, bz = -1, nil :: number?, 0, 0
	for _, impact in finals do
		if impact.kind ~= "none" then
			local dx, dy, dz = impact.x - ox, impact.y - oy, impact.z - oz
			local d = dx * dx + dy * dy + dz * dz
			if d >= least and d > best then
				best, bx, by, bz = d, impact.x, impact.y, impact.z
			end
		end
	end
	return bx, by, bz
end

--[[ The Shots message ]]

-- What an impact hit, as the Shots message says (Net/WeaponSync.Hit).
function FireRules.hitKind(impact: Ballistics.Impact): number
	local Hit = WeaponSync.Hit
	local kind = impact.kind
	if kind == "block" then
		return Hit.Block
	elseif kind == "glass" then
		return Hit.Glass
	elseif kind == "mob" then
		return if impact.head then Hit.MobHead else Hit.Mob
	elseif kind == "player" then
		return if impact.head then Hit.PlayerHead else Hit.Player
	end
	return Hit.None
end

-- The record of an accepted shot (see the header): `shooter` the UserId.
function FireRules.record(
	shooter: number,
	fire: WeaponSync.Fire,
	suppressed: boolean,
	jammed: boolean,
	finals: { Ballistics.Impact }
): WeaponSync.Shot
	local pellets: { WeaponSync.Pellet } = table.create(math.min(#finals, WeaponSync.MAX_PELLETS))
	for i, impact in finals do
		if i > WeaponSync.MAX_PELLETS then
			break
		end
		pellets[i] = {
			x = math.clamp(impact.x, -LIMIT, LIMIT),
			y = math.clamp(impact.y, -Y_LIMIT, Y_LIMIT),
			z = math.clamp(impact.z, -LIMIT, LIMIT),
			hit = FireRules.hitKind(impact),
		}
	end
	return {
		shooter = shooter,
		item = fire.item,
		shot = fire.shot,
		suppressed = suppressed,
		jammed = jammed,
		refused = false,
		ox = fire.ox,
		oy = fire.oy,
		oz = fire.oz,
		pellets = pellets,
	}
end

-- The shooter's record of a refused shot (see the header).
function FireRules.refused(shooter: number, fire: WeaponSync.Fire, reason: string): WeaponSync.Shot
	return {
		shooter = shooter,
		item = fire.item,
		shot = fire.shot,
		suppressed = false,
		jammed = reason == WeaponState.JAMMED,
		refused = true,
		ox = fire.ox,
		oy = fire.oy,
		oz = fire.oz,
		pellets = {},
	}
end

-- Who is sent a shot fired at (ox, oz): the shooter first, then every other listener within
-- ShotBroadcast blocks horizontally.
function FireRules.audience(listeners: { PlayerCandidate }, ox: number, oz: number, shooter: any, s: Settings): { any }
	local out: { any } = { shooter }
	local range = s.ShotBroadcast * s.ShotBroadcast
	for _, listener in listeners do
		if listener.key ~= shooter then
			local dx, dz = listener.x - ox, listener.z - oz
			if dx * dx + dz * dz <= range then
				table.insert(out, listener.key)
			end
		end
	end
	return out
end

--[[ Bolts ]]

-- Where a round of `ammo` that ended at `impact` drops again (see the header), given a `roll` in
-- [0, 1): the position, nil for none.
function FireRules.recovery(
	ammo: Weapons.AmmoSpec,
	impact: Ballistics.Impact,
	roll: number,
	s: Settings
): (number?, number, number)
	if not ammo.recover then
		return nil, 0, 0
	end
	local kind = impact.kind
	if kind == "block" or kind == "glass" then
		if roll < s.BoltRecover then
			local back = FireRules.BOLT_BACK
			return impact.x - (impact.dx or 0) * back,
				impact.y - (impact.dy or 0) * back,
				impact.z - (impact.dz or 0) * back
		end
	elseif kind == "mob" or kind == "player" then
		if roll < s.BoltRecover / 2 then
			return impact.x, impact.y, impact.z
		end
	end
	return nil, 0, 0
end

return FireRules
