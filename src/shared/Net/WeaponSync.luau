--!strict
--[[
	Weapon messages (Shared/Weapons; server Weapons/, client Interaction/Firearms and
	Rendering/ShotView), apart from Net/Protocol as Net/MagicSync is: codecs only, pure. Ids:
	Protocol.ClientMessage.Fire and Weapon, Protocol.ServerMessage.Shots.

	Client -> server
	  Fire    u32 seq (the inventory action number of the predicted `fire`: ClientInventory.fire),
	          u16 shot (the client's shot counter, wrapping), u8 slot (the hotbar slot, 1..9), u16
	          item (the firearm the client thinks it holds), u8 flags (bit 0 in the sights, 1
	          moving, 2 crouching, 3 holding breath; the others 0), f64 ox, oy, oz (the eyes,
	          world blocks), f32 dx, dy, dz (the aim, a unit vector): 46 bytes. Another length,
	          non-finite numbers, an origin beyond Protocol.MAX_COORDINATE + 64 (y beyond 4096), a
	          direction more than DIRECTION_SLACK from unit length, a slot outside 1..9 or unknown
	          flags are malformed.
	  Weapon  u8 op (Op: 1 raise, 2 lower, 3 guard, 4 unguard): 1 byte; another op or length is
	          malformed.
	Server -> client
	  Shots   u8 count (1..MAX_SHOTS), count x shot: f64 shooter (the UserId; whole), u16 item
	          (the firearm), u16 shot (the shooter's counter), u8 flags (bit 0 suppressed, 1 the
	          gun jammed after this shot, 2 refused: the shooter's alone, no pellets, 3 plain:
	          tracers without glow, a suppressed turret's), f32 ox, oy,
	          oz (where it was fired from), u8 n (0..MAX_PELLETS), n x (f32 x, y, z: where the
	          pellet's flight ended, u8 hit: Hit's kinds). 26 + 13 n bytes a shot. Non-finite
	          numbers, positions beyond Protocol.MAX_COORDINATE + 64 (y beyond 4096), unknown
	          flags or hits, a refused shot with pellets, a wrong length are malformed.
	          A turret's shot (Shared/Turrets, server Turrets/TurretWorld) is a Shots record with
	          shooter 0 (no player: clients draw it from its origin, the turret's muzzle), its
	          stand-in gun as the item and the turret's own counter; `plain` came with the turrets
	          (an older client refuses bit 3, so both ends ship together).
]]

local Protocol = require(script.Parent.Protocol)

-- A Fire message (see the header).
export type Fire = {
	seq: number,
	shot: number,
	slot: number,
	item: number,
	sights: boolean,
	moving: boolean,
	crouching: boolean,
	breath: boolean,
	ox: number,
	oy: number,
	oz: number,
	dx: number,
	dy: number,
	dz: number,
}

-- Where one pellet's flight ended and what it hit (Hit).
export type Pellet = { x: number, y: number, z: number, hit: number }

-- One shot of a Shots message (see the header).
export type Shot = {
	shooter: number,
	item: number,
	shot: number,
	suppressed: boolean,
	jammed: boolean,
	refused: boolean,
	-- Tracers without glow (a turret's suppressed shot: its device's `glow` false); nil: false.
	plain: boolean?,
	ox: number,
	oy: number,
	oz: number,
	pellets: { Pellet },
}

local WeaponSync = {}

WeaponSync.FIRE_BYTES = 46
WeaponSync.WEAPON_BYTES = 1
-- Shots a Shots message carries at most, pellets a shot.
WeaponSync.MAX_SHOTS = 64
WeaponSync.MAX_PELLETS = 12
-- A Shots record's bytes before its pellets, and a pellet's.
WeaponSync.SHOT_BYTES = 26
WeaponSync.PELLET_BYTES = 13
-- How far from unit length a Fire's direction may be.
WeaponSync.DIRECTION_SLACK = 0.01
-- What a pellet hit: nothing (its flight ended), a block, glass, a mob's body or head, a player's
-- body or head.
WeaponSync.Hit = table.freeze({ None = 0, Block = 1, Glass = 2, Mob = 3, MobHead = 4, Player = 5, PlayerHead = 6 })
-- The Weapon message's ops.
WeaponSync.Op = table.freeze({ Raise = 1, Lower = 2, Guard = 3, Unguard = 4 })
-- Fire flags.
WeaponSync.FireFlag = table.freeze({ Sights = 1, Moving = 2, Crouching = 4, Breath = 8 })
-- Shots flags.
WeaponSync.ShotFlag = table.freeze({ Suppressed = 1, Jammed = 2, Refused = 4, Plain = 8 })

local LIMIT = Protocol.MAX_COORDINATE + 64
local Y_LIMIT = 4096
local MAX_HIT = 6

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

local function validPlace(x: number, y: number, z: number): boolean
	return finite(x)
		and finite(y)
		and finite(z)
		and math.abs(x) <= LIMIT
		and math.abs(z) <= LIMIT
		and math.abs(y) <= Y_LIMIT
end

--[[ Client -> server ]]

function WeaponSync.encodeFire(fire: Fire): buffer
	local b = buffer.create(WeaponSync.FIRE_BYTES)
	local flags = (if fire.sights then 1 else 0)
		+ (if fire.moving then 2 else 0)
		+ (if fire.crouching then 4 else 0)
		+ (if fire.breath then 8 else 0)
	buffer.writeu32(b, 0, fire.seq % 4294967296)
	buffer.writeu16(b, 4, fire.shot % 65536)
	buffer.writeu8(b, 6, fire.slot)
	buffer.writeu16(b, 7, fire.item)
	buffer.writeu8(b, 9, flags)
	buffer.writef64(b, 10, fire.ox)
	buffer.writef64(b, 18, fire.oy)
	buffer.writef64(b, 26, fire.oz)
	buffer.writef32(b, 34, fire.dx)
	buffer.writef32(b, 38, fire.dy)
	buffer.writef32(b, 42, fire.dz)
	return b
end

-- The shot, nil when malformed (see the header).
function WeaponSync.decodeFire(b: buffer): Fire?
	if buffer.len(b) ~= WeaponSync.FIRE_BYTES then
		return nil
	end
	local slot, flags = buffer.readu8(b, 6), buffer.readu8(b, 9)
	if slot < 1 or slot > 9 or flags > 15 then
		return nil
	end
	local ox, oy, oz = buffer.readf64(b, 10), buffer.readf64(b, 18), buffer.readf64(b, 26)
	local dx, dy, dz = buffer.readf32(b, 34), buffer.readf32(b, 38), buffer.readf32(b, 42)
	if not validPlace(ox, oy, oz) or not (finite(dx) and finite(dy) and finite(dz)) then
		return nil
	end
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if math.abs(length - 1) > WeaponSync.DIRECTION_SLACK then
		return nil
	end
	return {
		seq = buffer.readu32(b, 0),
		shot = buffer.readu16(b, 4),
		slot = slot,
		item = buffer.readu16(b, 7),
		sights = bit32.btest(flags, 1),
		moving = bit32.btest(flags, 2),
		crouching = bit32.btest(flags, 4),
		breath = bit32.btest(flags, 8),
		ox = ox,
		oy = oy,
		oz = oz,
		dx = dx,
		dy = dy,
		dz = dz,
	}
end

function WeaponSync.encodeWeapon(op: number): buffer
	local b = buffer.create(WeaponSync.WEAPON_BYTES)
	buffer.writeu8(b, 0, op)
	return b
end

-- The op (WeaponSync.Op), nil when malformed.
function WeaponSync.decodeWeapon(b: buffer): number?
	if buffer.len(b) ~= WeaponSync.WEAPON_BYTES then
		return nil
	end
	local op = buffer.readu8(b, 0)
	if op < WeaponSync.Op.Raise or op > WeaponSync.Op.Unguard then
		return nil
	end
	return op
end

--[[ Server -> client ]]

-- The first MAX_SHOTS of `shots` (at least one; MAX_PELLETS pellets a shot at most).
function WeaponSync.encodeShots(shots: { Shot }): buffer
	local count = math.min(#shots, WeaponSync.MAX_SHOTS)
	local size = 1
	for i = 1, count do
		size += WeaponSync.SHOT_BYTES + WeaponSync.PELLET_BYTES * math.min(#shots[i].pellets, WeaponSync.MAX_PELLETS)
	end
	local b = buffer.create(size)
	buffer.writeu8(b, 0, count)
	local o = 1
	for i = 1, count do
		local shot = shots[i]
		local n = math.min(#shot.pellets, WeaponSync.MAX_PELLETS)
		buffer.writef64(b, o, shot.shooter)
		buffer.writeu16(b, o + 8, shot.item)
		buffer.writeu16(b, o + 10, shot.shot % 65536)
		buffer.writeu8(
			b,
			o + 12,
			(if shot.suppressed then 1 else 0)
				+ (if shot.jammed then 2 else 0)
				+ (if shot.refused then 4 else 0)
				+ (if shot.plain then 8 else 0)
		)
		buffer.writef32(b, o + 13, shot.ox)
		buffer.writef32(b, o + 17, shot.oy)
		buffer.writef32(b, o + 21, shot.oz)
		buffer.writeu8(b, o + 25, n)
		o += WeaponSync.SHOT_BYTES
		for j = 1, n do
			local pellet = shot.pellets[j]
			buffer.writef32(b, o, pellet.x)
			buffer.writef32(b, o + 4, pellet.y)
			buffer.writef32(b, o + 8, pellet.z)
			buffer.writeu8(b, o + 12, pellet.hit)
			o += WeaponSync.PELLET_BYTES
		end
	end
	return b
end

-- The shots, nil when malformed (see the header).
function WeaponSync.decodeShots(b: buffer): { Shot }?
	local len = buffer.len(b)
	if len < 1 then
		return nil
	end
	local count = buffer.readu8(b, 0)
	if count < 1 or count > WeaponSync.MAX_SHOTS then
		return nil
	end
	local shots: { Shot } = table.create(count)
	local o = 1
	for i = 1, count do
		if o + WeaponSync.SHOT_BYTES > len then
			return nil
		end
		local shooter = buffer.readf64(b, o)
		local flags = buffer.readu8(b, o + 12)
		local ox, oy, oz = buffer.readf32(b, o + 13), buffer.readf32(b, o + 17), buffer.readf32(b, o + 21)
		local n = buffer.readu8(b, o + 25)
		local refused = bit32.btest(flags, 4)
		if
			not finite(shooter)
			or shooter ~= math.floor(shooter)
			or flags > 15
			or not validPlace(ox, oy, oz)
			or n > WeaponSync.MAX_PELLETS
			or (refused and n > 0)
		then
			return nil
		end
		local shot: Shot = {
			shooter = shooter,
			item = buffer.readu16(b, o + 8),
			shot = buffer.readu16(b, o + 10),
			suppressed = bit32.btest(flags, 1),
			jammed = bit32.btest(flags, 2),
			refused = refused,
			plain = bit32.btest(flags, 8),
			ox = ox,
			oy = oy,
			oz = oz,
			pellets = table.create(n),
		}
		o += WeaponSync.SHOT_BYTES
		if o + n * WeaponSync.PELLET_BYTES > len then
			return nil
		end
		for j = 1, n do
			local x, y, z = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
			local hit = buffer.readu8(b, o + 12)
			if not validPlace(x, y, z) or hit > MAX_HIT then
				return nil
			end
			shot.pellets[j] = { x = x, y = y, z = z, hit = hit }
			o += WeaponSync.PELLET_BYTES
		end
		shots[i] = shot
	end
	if o ~= len then
		return nil
	end
	return shots
end

return WeaponSync
