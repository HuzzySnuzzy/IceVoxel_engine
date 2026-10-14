--!strict
--[[
	Which zombie groans when, pure (Entities/MobRenderer plays `entity.zombie.ambient` through
	Audio/SoundPlayer at the zombie it names; tests/spec/ZombieVoices checks it). Groans are this
	client's own: the server sends no event for them, so they cost the network nothing and every
	player hears the zombies round themselves.

	  Who       only the NEAREST (8) live zombies within RADIUS (24) blocks of the listener (the
	            event's own reach, 16, when shorter: one too far to hear would only waste a turn).
	  When      each zombie groans every 6 to 20 s, its own period from its id (Util/Hash), the
	            first one a hashed share of that period after it is first heard; when several
	            are due, the longest overdue goes first.
	  How many  at most one groan every GAP (1.5) s in all, however many zombies are near:
	            Minecraft's Mob.getAmbientSoundInterval (80 ticks, a 1/1000 roll a tick after it)
	            makes a crowd a din; here a horde murmurs.
	  Voices    the event's pitch (Shared/Sounds) times the gait's: the brute lower, the runner
	            and the screamer higher, the crawler a little lower.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Hash = require(Shared.Util.Hash)

local U32 = 4294967296

local ZombieVoices = {}

ZombieVoices.NEAREST = 8
ZombieVoices.RADIUS = 24
ZombieVoices.GAP = 1.5
ZombieVoices.PERIOD = { 6, 20 }
-- Pitch times this by the zombie's gait (MobList rig.gait).
ZombieVoices.PITCH = table.freeze({ shamble = 1, run = 1.12, brute = 0.75, crawl = 0.9, lurch = 1.3 })

export type Voices = {
	-- When each zombie heard so far groans next (os.clock seconds).
	due: { [number]: number },
	-- When the last groan was.
	last: number,
}

function ZombieVoices.new(): Voices
	return { due = {}, last = -math.huge }
end

-- Seconds between a zombie's groans (6..20, from its id).
function ZombieVoices.period(id: number): number
	local range = ZombieVoices.PERIOD
	return range[1] + (range[2] - range[1]) * Hash.hash2(id % U32, 0x6A0A, 0x11) / U32
end

--[[
	The id of the zombie that groans at `now`, or nil: of `ids[1..count]` (live zombies, nearest
	first, `distances` in blocks) the nearest NEAREST within `radius` (RADIUS when nil), at most
	one every GAP seconds in all.
]]
function ZombieVoices.step(
	voices: Voices,
	now: number,
	count: number,
	ids: { number },
	distances: { number },
	radius: number?
): number?
	local reach = radius or ZombieVoices.RADIUS
	local due = voices.due
	local pick: number? = nil
	local pickDue = math.huge
	local heard = 0
	for i = 1, count do
		if heard >= ZombieVoices.NEAREST or distances[i] > reach then
			break
		end
		heard += 1
		local id = ids[i]
		local at = due[id]
		if at == nil then
			-- First heard: a hashed share of its period from now.
			at = now + ZombieVoices.period(id) * Hash.hash2(id % U32, 0x6A0B, 0x12) / U32
			due[id] = at
		end
		if at <= now and at < pickDue then
			pick, pickDue = id, at
		end
	end
	if pick == nil or now - voices.last < ZombieVoices.GAP then
		return nil
	end
	voices.last = now
	due[pick] = now + ZombieVoices.period(pick)
	return pick
end

-- A zombie gone (removed or out of range): its timing is dropped.
function ZombieVoices.forget(voices: Voices, id: number)
	voices.due[id] = nil
end

return ZombieVoices
