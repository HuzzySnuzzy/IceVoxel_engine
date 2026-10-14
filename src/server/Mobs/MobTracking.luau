--!strict
--[[
	What each player's client is told about the mobs around them (pure; Mobs/Mobs sends it every
	Config.Mobs.SyncTicks in one Protocol Mobs message a player, with their knockback).

	  State     a mob as the message carries it (`snapshot`): its feet in whole 1/32 block steps
	            (Protocol.MOB_POSITION_SCALE), its facing in 1/256 turns, its health (half hearts,
	            rounded up) and its flags (Protocol.MobFlag): the hurt flash, burning, dying,
	            aggressive (a target, or a blood moon hunt), attacking (a melee swing in its last 8
	            ticks), breaking a block and screaming (Mobs/MobAI's `swing`, `bx`, `scream`).
	  Spawn     a mob comes into view within Config.Mobs.TrackingDistance (64) of the player's
	            feet: op 1 with its kind and variant (at most MAX_SPAWNS a message, the rest at the
	            next sync).
	  Remove    it goes out of view only beyond TrackingDistance + HYSTERESIS (8), or is gone (op
	            3), so one walking along the edge isn't spawned and removed over and over.
	  Changes   while in view, a mob whose state changed sends a move (op 6, 14 bytes): the change
	            of its position from the one last sent to this player, in whole steps, which the
	            client adds to the position it last decoded, so the two never drift apart; when a
	            step would not fit an i16 (Protocol.MOB_DELTA_LIMIT) a state (op 2, its whole
	            position) goes instead. Mobs farther than FAR (32) blocks are looked at every other
	            sync (by their id: half of them each time), five times a second; a dying one every
	            sync, so its fall shows.
	`seen` is what the player's client knows: each mob's last sent state. 60 zombies on the move
	cost 2 + 60 x 14 = 842 bytes a sync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local MobWorld = require(script.Parent.MobWorld)

export type Sent = { x: number, y: number, z: number, yaw: number, health: number, flags: number }

local MobTracking = {}

-- Spawns a message at most; blocks beyond the tracking distance a mob stays in view; beyond FAR
-- blocks it is looked at every other sync.
MobTracking.MAX_SPAWNS = 128
MobTracking.HYSTERESIS = 8
MobTracking.FAR = 32

local FLAGS = Protocol.MobFlag
local SCALE = Protocol.MOB_POSITION_SCALE
local LIMIT = Protocol.MOB_DELTA_LIMIT

-- A mob's flags (see the header).
function MobTracking.flags(mob: MobWorld.Mob): number
	local ai = mob.ai
	local living = not mob.dead
	return (if mob.hurtTime > 0 then FLAGS.Hurt else 0)
		+ (if mob.burn.fire > 0 then FLAGS.Burning else 0)
		+ (if mob.dead then FLAGS.Dying else 0)
		+ (if living and (ai.target ~= nil or ai.hunt ~= nil) then FLAGS.Aggressive else 0)
		+ (if living and ai.swing > 0 then FLAGS.Attack else 0)
		+ (if living and ai.bx ~= nil then FLAGS.Breaking else 0)
		+ (if living and ai.scream > 0 then FLAGS.Screaming else 0)
end

-- A mob's state as the message carries it (see the header).
function MobTracking.snapshot(mob: MobWorld.Mob): Sent
	local body = mob.body
	return {
		x = math.round(body.x * SCALE),
		y = math.round(body.y * SCALE),
		z = math.round(body.z * SCALE),
		yaw = Protocol.mobYaw(body.yaw),
		health = math.clamp(math.ceil(mob.health), 0, 255),
		flags = MobTracking.flags(mob),
	}
end

local function same(a: Sent, b: Sent): boolean
	return a.x == b.x and a.y == b.y and a.z == b.z and a.yaw == b.yaw and a.health == b.health and a.flags == b.flags
end

--[[
	Appends to `ops` what brings a player's view up to date (see the header): `seen` what their
	client knows (updated), `all` the mobs, `states` their states now (MobTracking.snapshot, shared
	by every player's view: never changed after), (px, py, pz) the player's feet (px nil: no
	position, so every mob is removed), `range` the tracking distance and `sync` the sync's number.
]]
function MobTracking.ops(
	ops: { Protocol.MobOp },
	seen: { [number]: Sent },
	all: { MobWorld.Mob },
	states: { [number]: Sent },
	px: number?,
	py: number,
	pz: number,
	range: number,
	sync: number
)
	local spawnSq = range * range
	local keep = range + MobTracking.HYSTERESIS
	local keepSq = keep * keep
	local farSq = MobTracking.FAR * MobTracking.FAR
	local inView: { [number]: boolean } = {}
	local spawns = 0
	if px then
		for _, mob in all do
			local body = mob.body
			local dx, dy, dz = body.x - px, body.y - py, body.z - pz
			local distance = dx * dx + dy * dy + dz * dz
			local id = mob.id
			local last = seen[id]
			if last == nil then
				if distance <= spawnSq and spawns < MobTracking.MAX_SPAWNS then
					local now = states[id]
					spawns += 1
					inView[id] = true
					seen[id] = now
					table.insert(ops, {
						op = "spawn",
						id = id,
						kind = mob.kind.id,
						variant = mob.variant,
						x = now.x / SCALE,
						y = now.y / SCALE,
						z = now.z / SCALE,
						yaw = body.yaw,
						health = now.health,
						flags = now.flags,
					})
				end
			elseif distance <= keepSq then
				inView[id] = true
				local now = states[id]
				local due = distance <= farSq or (sync + id) % 2 == 0 or mob.dead
				if due and not same(last, now) then
					seen[id] = now
					local sx, sy, sz = now.x - last.x, now.y - last.y, now.z - last.z
					if
						sx >= -LIMIT
						and sx <= LIMIT
						and sy >= -LIMIT
						and sy <= LIMIT
						and sz >= -LIMIT
						and sz <= LIMIT
					then
						table.insert(ops, {
							op = "move",
							id = id,
							dx = sx / SCALE,
							dy = sy / SCALE,
							dz = sz / SCALE,
							yaw = body.yaw,
							health = now.health,
							flags = now.flags,
						})
					else
						table.insert(ops, {
							op = "state",
							id = id,
							x = now.x / SCALE,
							y = now.y / SCALE,
							z = now.z / SCALE,
							yaw = body.yaw,
							health = now.health,
							flags = now.flags,
						})
					end
				end
			end
		end
	end
	for id in seen do
		if not inView[id] then
			seen[id] = nil
			table.insert(ops, { op = "remove", id = id })
		end
	end
end

return MobTracking
