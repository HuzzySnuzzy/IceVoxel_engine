--!strict
--[[
	Mana and magic messages (Shared/Mana, server Players/Mana and Players/Magic, client
	Player/ManaState and Rendering/ProjectileView), apart from Net/Protocol as Net/PlayerSync is:
	codecs only, pure. Ids: Protocol.ClientMessage.HeldUse, Protocol.ServerMessage.Mana and
	Projectiles. Positions are world blocks (f32: a projectile lives a few seconds near its
	caster, and Protocol.MAX_COORDINATE keeps a block's 1/64 within f32), velocities blocks a tick.

	Client -> server
	  HeldUse      u16 seq (the client's count, wrapping), u8 slot (the hotbar slot, 1..9), u16
	               item (what the client thinks it holds), f32 dx, dy, dz (where it aims, from the
	               camera: a unit vector; ignored by a Mana Crystal): use the held item without a
	               block (a magic weapon casts, a Mana Crystal is used up). Non-finite numbers, a
	               direction far from unit length or another slot are malformed.
	Server -> client
	  Mana         u16 mana (whole), u16 max, u8 flags (bit 0 a cast was refused for want of mana,
	               bit 1 mana just became full: Terraria's chime): 5 bytes, to the player alone
	               when the whole number changes (at most every few ticks) and at once after a
	               cast, a potion, a crystal or a respawn. Other flags or mana above the max are
	               malformed.
	  Projectiles  u16 count, count x op (u8 op, u32 id, then by op):
	                 1 spawn  u8 kind (Shared/Magic's index, 1..kinds), f64 owner (the caster's
	                          UserId), u16 seq (the caster's HeldUse, so its client adopts the
	                          projectile it already flies), f32 x, y, z, f32 vx, vy, vz
	                 2 sync   f32 x, y, z, f32 vx, vy, vz: where it is now (after a bounce)
	                 3 end    f32 x, y, z, u8 reason (Reason: 0 expired, 1 hit a block, 2 hit a
	                          mob)
	               Every client flies each projectile itself with the same pure step (as items in
	               transporters: nothing is sent per tick). An unknown op, kind or reason,
	               non-finite numbers, coordinates past Protocol.MAX_COORDINATE or a speed over
	               MAX_SPEED are malformed.
]]

local Protocol = require(script.Parent.Protocol)

export type HeldUse = { seq: number, slot: number, item: number, dx: number, dy: number, dz: number }

export type ManaStatus = { mana: number, max: number, refused: boolean, full: boolean }

export type ProjectileOp = {
	op: "spawn" | "sync" | "end",
	id: number,
	-- spawn
	kind: number?,
	owner: number?,
	seq: number?,
	-- spawn, sync, end
	x: number,
	y: number,
	z: number,
	-- spawn, sync
	vx: number?,
	vy: number?,
	vz: number?,
	-- end
	reason: number?,
}

local MagicSync = {}

MagicSync.HELD_USE_BYTES = 17
MagicSync.MANA_BYTES = 5
-- Blocks a tick a projectile may fly at most (the fastest kind is far below).
MagicSync.MAX_SPEED = 8
-- Why a projectile ended.
MagicSync.Reason = table.freeze({ Expired = 0, Block = 1, Mob = 2 })
MagicSync.Op = table.freeze({ spawn = 1, sync = 2, ["end"] = 3 } :: { [string]: number })

local OP_NAMES: { [number]: "spawn" | "sync" | "end" } = { "spawn", "sync", "end" }
-- Bytes after (u8 op, u32 id) by op.
local OP_BYTES = { 1 + 8 + 2 + 24, 24, 13 }
local Y_LIMIT = 2 ^ 20

local function finite(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

--[[ Client -> server ]]

function MagicSync.encodeHeldUse(use: HeldUse): buffer
	local b = buffer.create(MagicSync.HELD_USE_BYTES)
	buffer.writeu16(b, 0, use.seq % 65536)
	buffer.writeu8(b, 2, use.slot)
	buffer.writeu16(b, 3, use.item)
	buffer.writef32(b, 5, use.dx)
	buffer.writef32(b, 9, use.dy)
	buffer.writef32(b, 13, use.dz)
	return b
end

-- The use, nil when malformed (see the header).
function MagicSync.decodeHeldUse(b: buffer): HeldUse?
	if buffer.len(b) ~= MagicSync.HELD_USE_BYTES then
		return nil
	end
	local slot = buffer.readu8(b, 2)
	local dx, dy, dz = buffer.readf32(b, 5), buffer.readf32(b, 9), buffer.readf32(b, 13)
	if slot < 1 or slot > 9 or not (finite(dx) and finite(dy) and finite(dz)) then
		return nil
	end
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length < 0.9 or length > 1.1 then
		return nil
	end
	return { seq = buffer.readu16(b, 0), slot = slot, item = buffer.readu16(b, 3), dx = dx, dy = dy, dz = dz }
end

--[[ Server -> client ]]

function MagicSync.encodeMana(status: ManaStatus): buffer
	local b = buffer.create(MagicSync.MANA_BYTES)
	local max = math.clamp(math.floor(status.max), 0, 65535)
	buffer.writeu16(b, 0, math.clamp(math.floor(status.mana), 0, max))
	buffer.writeu16(b, 2, max)
	buffer.writeu8(b, 4, (if status.refused then 1 else 0) + (if status.full then 2 else 0))
	return b
end

function MagicSync.decodeMana(b: buffer): ManaStatus?
	if buffer.len(b) ~= MagicSync.MANA_BYTES then
		return nil
	end
	local mana, max, flags = buffer.readu16(b, 0), buffer.readu16(b, 2), buffer.readu8(b, 4)
	if mana > max or flags > 3 then
		return nil
	end
	return { mana = mana, max = max, refused = bit32.btest(flags, 1), full = bit32.btest(flags, 2) }
end

local function writeVector(b: buffer, o: number, x: number, y: number, z: number): number
	buffer.writef32(b, o, x)
	buffer.writef32(b, o + 4, y)
	buffer.writef32(b, o + 8, z)
	return o + 12
end

function MagicSync.encodeProjectiles(ops: { ProjectileOp }): buffer
	local count = math.min(#ops, 65535)
	local size = 2
	for i = 1, count do
		size += 5 + OP_BYTES[MagicSync.Op[ops[i].op]]
	end
	local b = buffer.create(size)
	buffer.writeu16(b, 0, count)
	local o = 2
	for i = 1, count do
		local op = ops[i]
		local code = MagicSync.Op[op.op]
		buffer.writeu8(b, o, code)
		buffer.writeu32(b, o + 1, op.id)
		o += 5
		if op.op == "spawn" then
			buffer.writeu8(b, o, op.kind or 0)
			buffer.writef64(b, o + 1, op.owner or 0)
			buffer.writeu16(b, o + 9, (op.seq or 0) % 65536)
			o = writeVector(b, o + 11, op.x, op.y, op.z)
			o = writeVector(b, o, op.vx or 0, op.vy or 0, op.vz or 0)
		elseif op.op == "sync" then
			o = writeVector(b, o, op.x, op.y, op.z)
			o = writeVector(b, o, op.vx or 0, op.vy or 0, op.vz or 0)
		else
			o = writeVector(b, o, op.x, op.y, op.z)
			buffer.writeu8(b, o, op.reason or 0)
			o += 1
		end
	end
	return b
end

local function validPlace(x: number, y: number, z: number): boolean
	return finite(x)
		and finite(y)
		and finite(z)
		and math.abs(x) <= Protocol.MAX_COORDINATE
		and math.abs(z) <= Protocol.MAX_COORDINATE
		and math.abs(y) <= Y_LIMIT
end

local function validVelocity(vx: number, vy: number, vz: number): boolean
	return finite(vx)
		and finite(vy)
		and finite(vz)
		and vx * vx + vy * vy + vz * vz <= MagicSync.MAX_SPEED * MagicSync.MAX_SPEED
end

-- The ops, nil when malformed (see the header); `kinds` is how many projectile kinds there are.
function MagicSync.decodeProjectiles(b: buffer, kinds: number): { ProjectileOp }?
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	local ops: { ProjectileOp } = table.create(count)
	local o = 2
	for i = 1, count do
		if o + 5 > len then
			return nil
		end
		local code = buffer.readu8(b, o)
		local name = OP_NAMES[code]
		if name == nil or o + 5 + OP_BYTES[code] > len then
			return nil
		end
		local id = buffer.readu32(b, o + 1)
		o += 5
		local op: ProjectileOp
		if name == "spawn" then
			local kind = buffer.readu8(b, o)
			local owner = buffer.readf64(b, o + 1)
			local seq = buffer.readu16(b, o + 9)
			local x, y, z = buffer.readf32(b, o + 11), buffer.readf32(b, o + 15), buffer.readf32(b, o + 19)
			local vx, vy, vz = buffer.readf32(b, o + 23), buffer.readf32(b, o + 27), buffer.readf32(b, o + 31)
			if
				kind < 1
				or kind > kinds
				or not finite(owner)
				or not validPlace(x, y, z)
				or not validVelocity(vx, vy, vz)
			then
				return nil
			end
			op = {
				op = "spawn",
				id = id,
				kind = kind,
				owner = owner,
				seq = seq,
				x = x,
				y = y,
				z = z,
				vx = vx,
				vy = vy,
				vz = vz,
			}
		elseif name == "sync" then
			local x, y, z = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
			local vx, vy, vz = buffer.readf32(b, o + 12), buffer.readf32(b, o + 16), buffer.readf32(b, o + 20)
			if not validPlace(x, y, z) or not validVelocity(vx, vy, vz) then
				return nil
			end
			op = { op = "sync", id = id, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz }
		else
			local x, y, z = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
			local reason = buffer.readu8(b, o + 12)
			if not validPlace(x, y, z) or reason > MagicSync.Reason.Mob then
				return nil
			end
			op = { op = "end", id = id, x = x, y = y, z = z, reason = reason }
		end
		o += OP_BYTES[code]
		ops[i] = op
	end
	if o ~= len then
		return nil
	end
	return ops
end

return MagicSync
