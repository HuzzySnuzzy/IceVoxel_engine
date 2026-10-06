--!strict
--[[
	The rules behind the client's sounds (Audio/SoundPlayer, Audio/MovementSounds, Audio/Ambience).
	Pure (no Roblox APIs), so the tests check them.

	  playback   what an event plays as (`playback`): its file, or its `fallback` once the file
	             failed to load; Sound.Volume, the event's (or a developer's replacement Sound's)
	             times the cue's, Config.Sounds.Volume and the event's source volume; the
	             PlaybackSpeed, the event's pitch (or the replacement's PlaybackSpeed) varied by
	             the event's pitch variance, times the cue's; how long it plays (`duration` of the
	             file / pitch); how far it is heard (the event's maxDistance, further for a cue
	             louder than 1, as Minecraft's sounds and the server's routing do).
	  listener   where the player hears from (`listenerAt`): the camera, at most LISTENER_REACH
	             blocks from the eyes.
	  files      whether a preloaded file failed (`loadFailed`; its events play their fallback): its
	             Sound never loaded, waiting LOAD_TIMEOUT seconds, or FAILED_GRACE after the
	             preload reported it failed (`loadPending`).
	  overrides  which replacement Sound plays (`chooseOverride`): the first name of
	             Sounds.lookupNames that has any (the event, then its category), one at random
	             when several share it (Minecraft's variants).
	  voices     the pool of Sound instances (`newPool`, `acquire`, `release`): a free voice;
	             else, when a kind of sound (an event's category or name) already has its most at
	             once (CAPS: overlapping mining hits, many footsteps), its oldest; else the oldest.
	  steps      Minecraft's footsteps (Entity.move, `move`): a walked distance growing by 0.6 per
	             block walked on the level, and the next whole number at which a step sounds, so a
	             step every 1.67 blocks. The step is the block under the feet (floor(y - 0.2));
	             fluids make none. In water off the ground it is a swim sound instead; entering
	             water splashes (not on the first tick); flying and sneaking on the ground are
	             silent (Player.getMovementEmission). In the air the step waits, so landing from
	             a jump sounds at once. `observe` guesses the ground and water of another
	             character from where its feet are.
	  hits       Minecraft's mining hit (MultiPlayerGameMode.destroyTicks): every HIT_INTERVAL
	             ticks on one block, from its first (`hitTick`).
	  ambience   a lit furnace crackles with Minecraft's odds for a furnace a block or two away
	             (CRACKLE_CHANCE per tick), and so does a burning Heat Generator within
	             CRACKLE_RANGE blocks (`crackles`); caves rumble now and then (`caveDelay`); lava
	             open to the air pops and bubbles (`lavaTick`: Minecraft's random display ticks,
	             sampled).
	  fluids     only fluids one swims in (Fluids `swim`: water, fuel) splash and make swim
	             sounds; lava and oil are silent to move through, as Minecraft's lava.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Fluids = require(Shared.Fluids)
local Sounds = require(Shared.Sounds)

type Event = Sounds.Event

local SoundRules = {}

-- Lowest PlaybackSpeed played (Sounds.pitch's floor).
SoundRules.MIN_PITCH = 0.05
-- Roblox's highest Sound.Volume.
SoundRules.MAX_VOLUME = 10

--[[ Playback ]]

-- The volume settings (Config.Sounds): the master volume and one per event source.
export type Settings = { Volume: number, Sources: { [string]: number } }

-- A developer's replacement Sound, as far as playing it goes (SoundId, Volume, PlaybackSpeed).
export type Override = { id: string, volume: number, speed: number }

export type Playback = {
	id: string,
	-- Sound.Volume and PlaybackSpeed.
	volume: number,
	pitch: number,
	-- Seconds of the file to play and the real seconds that takes (nil: all of it).
	duration: number?,
	length: number?,
	-- Blocks it is heard from.
	range: number,
}

-- `base` varied by up to `variance` of itself either way, for a random roll in [0, 1).
local function varied(base: number, variance: number, roll: number): number
	return base * (1 + (roll * 2 - 1) * variance)
end

--[[
	How event `event` plays: as the developer's `override` if there is one, else its file (its
	fallback when `failed[event.id]`), with the cue's volume and pitch multipliers, a random
	`roll` in [0, 1) for the pitch and the volume `settings`.
]]
function SoundRules.playback(
	event: Event,
	override: Override?,
	failed: { [string]: boolean }?,
	cueVolume: number,
	cuePitch: number,
	roll: number,
	settings: Settings
): Playback
	-- The variance as a share of the pitch, for pitches other than the event's own.
	local relative = if event.pitch > 0 then event.pitchVariance / event.pitch else 0
	local id: string, volume: number, pitch: number, duration: number?
	local fallback = event.fallback
	if override then
		id, volume, duration = override.id, override.volume, nil
		pitch = varied(override.speed, relative, roll)
	elseif fallback and failed and failed[event.id] then
		id, volume, duration = fallback.id, fallback.volume, fallback.duration
		pitch = varied(fallback.pitch, relative, roll)
	else
		id, volume, duration = event.id, event.volume, event.duration
		pitch = Sounds.pitch(event, roll)
	end
	local source = settings.Sources[event.source] or 1
	volume = math.clamp(volume * cueVolume * settings.Volume * source, 0, SoundRules.MAX_VOLUME)
	pitch = math.max(SoundRules.MIN_PITCH, pitch * cuePitch)
	return {
		id = id,
		volume = volume,
		pitch = pitch,
		duration = duration,
		length = if duration then duration / pitch else nil,
		range = SoundRules.range(event, cueVolume),
	}
end

-- Blocks event `event` is heard from at a cue volume (Minecraft: a sound louder than 1 carries
-- maxDistance x volume).
function SoundRules.range(event: Event, cueVolume: number): number
	return event.maxDistance * math.max(1, cueVolume)
end

--[[ Listener ]]

-- Farthest the listener gets from the eyes (blocks): Minecraft's third person camera distance.
SoundRules.LISTENER_REACH = 4

--[[
	Where the player hears from (blocks): the camera at (cx, cy, cz), as in Minecraft, but at most
	`reach` from the eyes it looks at (fx, fy, fz) along the same line. Roblox's camera zooms out
	much further than Minecraft's (128 studs by default), where everything near the player would
	fade out, and the server only sends sounds near the character.
]]
function SoundRules.listenerAt(
	cx: number,
	cy: number,
	cz: number,
	fx: number,
	fy: number,
	fz: number,
	reach: number
): (number, number, number)
	local dx, dy, dz = cx - fx, cy - fy, cz - fz
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	if distance <= reach then
		return cx, cy, cz
	end
	local scale = reach / distance
	return fx + dx * scale, fy + dy * scale, fz + dz * scale
end

--[[ Files ]]

-- What ContentProvider:PreloadAsync reported for a file (nil: nothing yet, or nothing at all,
-- which local rbxasset:// files may do).
export type LoadReport = "ok" | "failed"

-- Seconds a preloaded file may take to load, and how long one the preload reported failed is
-- still given (a local file may load although its preload "failed").
SoundRules.LOAD_TIMEOUT = 15
SoundRules.FAILED_GRACE = 2

--[[
	Whether the preload still waits for a file, `waited` seconds after the preload returned: its
	Sound has not loaded, the preload did not report it loaded, and its time is not up.
]]
function SoundRules.loadPending(loaded: boolean, report: LoadReport?, waited: number): boolean
	if loaded or report == "ok" then
		return false
	end
	return waited < (if report == "failed" then SoundRules.FAILED_GRACE else SoundRules.LOAD_TIMEOUT)
end

-- Whether a file failed once the wait is over (its events play their fallback): its Sound never
-- loaded and the preload did not report it loaded. A Sound that loaded always counts.
function SoundRules.loadFailed(loaded: boolean, report: LoadReport?): boolean
	return not loaded and report ~= "ok"
end

--[[ Overrides ]]

--[[
	The replacement for an event from `index` (name -> Sounds): the first of `names` (most specific
	first, Sounds.lookupNames) that has any, one of them picked by `roll` in [0, 1). nil when none.
]]
function SoundRules.chooseOverride<T>(index: { [string]: { T } }, names: { string }, roll: number): T?
	for _, name in names do
		local list = index[name]
		if list and #list > 0 then
			return list[math.clamp(math.floor(roll * #list) + 1, 1, #list)]
		end
	end
	return nil
end

--[[ Voices ]]

export type Voice = { busy: boolean, key: string, startedAt: number }
export type Pool = { voices: { Voice } }

-- Most voices one kind of sound (an event's category, else its name) has at once.
SoundRules.CAPS = table.freeze({
	-- A hit lasts about 0.6 s and comes every 0.2 s.
	["block.hit"] = 3,
	["block.step"] = 6,
	["entity.generic.swim"] = 3,
	["block.furnace.fire_crackle"] = 2,
	["ambient.cave"] = 1,
}) :: { [string]: number }
SoundRules.DEFAULT_CAP = 8

-- The kind of sound an event is, for the caps: its category, else its name.
function SoundRules.voiceKey(event: Event): string
	return event.category or event.name
end

function SoundRules.capOf(key: string): number
	return SoundRules.CAPS[key] or SoundRules.DEFAULT_CAP
end

function SoundRules.newPool(size: number): Pool
	local voices: { Voice } = table.create(size)
	for i = 1, size do
		voices[i] = { busy = false, key = "", startedAt = -math.huge }
	end
	return { voices = voices }
end

--[[
	Takes a voice for a sound of kind `key` starting at `now`, and returns its number: the oldest
	voice of that kind when it already has `cap` playing, else a free one, else the oldest of all
	(its sound is cut short).
]]
function SoundRules.acquire(pool: Pool, key: string, cap: number, now: number): number
	local same, sameIndex, sameAt = 0, 0, math.huge
	local free = 0
	local oldest, oldestAt = 1, math.huge
	for i, voice in pool.voices do
		if voice.busy then
			if voice.key == key then
				same += 1
				if voice.startedAt < sameAt then
					sameIndex, sameAt = i, voice.startedAt
				end
			end
			if voice.startedAt < oldestAt then
				oldest, oldestAt = i, voice.startedAt
			end
		elseif free == 0 then
			free = i
		end
	end
	local index = if same >= cap and sameIndex > 0 then sameIndex elseif free > 0 then free else oldest
	local voice = pool.voices[index]
	voice.busy, voice.key, voice.startedAt = true, key, now
	return index
end

-- Voice `index` is free again (its sound ended or was stopped).
function SoundRules.release(pool: Pool, index: number)
	pool.voices[index].busy = false
end

-- Voices of kind `key` playing.
function SoundRules.playing(pool: Pool, key: string): number
	local count = 0
	for _, voice in pool.voices do
		if voice.busy and voice.key == key then
			count += 1
		end
	end
	return count
end

--[[ Steps, swimming, splashes ]]

-- Walked distance per block (Entity.move: horizontal distance x 0.6): a step every 1 / 0.6 blocks.
SoundRules.STEP_SCALE = 0.6
-- The block stepped on is the one this far under the feet (Entity.getOnPos).
SoundRules.STEP_BELOW = 0.2
-- Feet within this many blocks of a block's top stand on it (other characters, `observe`).
SoundRules.GROUND_TOLERANCE = 0.08
-- Half the width of a player's hull (blocks).
local HALF_WIDTH = 0.3

--[[
	Swim and splash volumes follow Minecraft's weighted speed sqrt(0.2 vx^2 + vy^2 + 0.2 vz^2)
	(blocks per tick; Entity.waterSwimSound, doWaterSplashEffect), which Minecraft scales by 0.35
	and 0.2 into the sound's volume. The stand-in files are quieter, so the speed is taken relative
	to a typical one instead: these speeds play at the event's own volume.
]]
SoundRules.SWIM_SPEED = 0.12
SoundRules.SWIM_MIN, SoundRules.SWIM_MAX = 0.3, 1
SoundRules.SPLASH_SPEED = 0.4
SoundRules.SPLASH_MIN, SoundRules.SPLASH_MAX = 0.25, 1.5

export type Walker = {
	-- Minecraft's moveDist and nextStep.
	moveDist: number,
	nextStep: number,
	-- In water on the last move (nil: no move yet, so the first one never splashes).
	inWater: boolean?,
}

export type Motion = {
	-- Movement over this move (blocks) and how many ticks it took (1 for the local hull's ticks;
	-- frame time x 20 for other characters), for speeds.
	dx: number,
	dy: number,
	dz: number,
	ticks: number,
	onGround: boolean,
	inWater: boolean,
	swimming: boolean,
	-- Makes no sound: flying, or sneaking on the ground (Player.getMovementEmission).
	silent: boolean,
	-- The block under the feet (floor(y - STEP_BELOW)), nil where nothing is loaded.
	below: number?,
}

function SoundRules.newWalker(): Walker
	return { moveDist = 0, nextStep = 1, inWater = nil }
end

local function kindOf(block: number?): number
	if block == nil or not Blocks.isValid(block) then
		return Blocks.KIND_NONE
	end
	return Blocks.get(block).kind
end

-- Blocks one can stand on.
local function solid(block: number?): boolean
	return block ~= nil and Blocks.isValid(block) and Blocks.isSolid(block)
end

local function fluid(block: number?): boolean
	return kindOf(block) == Blocks.KIND_FLUID
end

-- A fluid one swims in (Fluids `swim`: water, fuel): it splashes and makes swim sounds.
local function swimmable(block: number?): boolean
	local record = if fluid(block) then Fluids.get(Fluids.ofBlock(block :: number)) else nil
	return record ~= nil and record.swim
end

local function weightedSpeed(motion: Motion): number
	local ticks = math.max(motion.ticks, 1e-3)
	local vx, vy, vz = motion.dx / ticks, motion.dy / ticks, motion.dz / ticks
	return math.sqrt(0.2 * vx * vx + vy * vy + 0.2 * vz * vz)
end

-- Volume multiplier of a swim sound for this motion.
function SoundRules.swimVolume(motion: Motion): number
	return math.clamp(weightedSpeed(motion) / SoundRules.SWIM_SPEED, SoundRules.SWIM_MIN, SoundRules.SWIM_MAX)
end

-- Volume multiplier of a splash for this motion (falling in from high up is louder).
function SoundRules.splashVolume(motion: Motion): number
	return math.clamp(weightedSpeed(motion) / SoundRules.SPLASH_SPEED, SoundRules.SPLASH_MIN, SoundRules.SPLASH_MAX)
end

--[[
	One move of a walker (Entity.move). Returns what sounds: the block whose step plays (nil:
	none), the volume multiplier of a swim sound (nil: none) and of a splash (nil: none).
]]
function SoundRules.move(walker: Walker, motion: Motion): (number?, number?, number?)
	local splash: number? = nil
	if motion.inWater and walker.inWater == false then
		splash = SoundRules.splashVolume(motion)
	end
	walker.inWater = motion.inWater
	if motion.silent then
		return nil, nil, splash
	end
	walker.moveDist += math.sqrt(motion.dx * motion.dx + motion.dz * motion.dz) * SoundRules.STEP_SCALE
	local below = motion.below
	if walker.moveDist <= walker.nextStep or below == nil or kindOf(below) == Blocks.KIND_NONE then
		return nil, nil, splash
	end
	if motion.onGround and not motion.swimming then
		walker.nextStep = math.floor(walker.moveDist) + 1
		return if fluid(below) then nil else below, nil, splash
	elseif motion.inWater then
		walker.nextStep = math.floor(walker.moveDist) + 1
		return nil, SoundRules.swimVolume(motion), splash
	end
	-- In the air: the step waits for the ground.
	return nil, nil, splash
end

export type GetBlock = (x: number, y: number, z: number) -> number?

--[[
	Another character's surroundings from its feet (blocks): whether it stands on something (feet
	at the top of a solid block under its hull), whether it is in water or fuel (a fluid one swims
	in, at the feet or the middle of the body) and the block it would step on (under the feet, or
	the solid block under its
	hull it stands on at an edge).
]]
function SoundRules.observe(getBlock: GetBlock, x: number, y: number, z: number): (boolean, boolean, number?)
	local floor = math.floor
	local by = floor(y - SoundRules.STEP_BELOW)
	local below = getBlock(floor(x), by, floor(z))
	local onGround = false
	if math.abs(y - (by + 1)) <= SoundRules.GROUND_TOLERANCE then
		if solid(below) then
			onGround = true
		else
			for bx = floor(x - HALF_WIDTH), floor(x + HALF_WIDTH) do
				for bz = floor(z - HALF_WIDTH), floor(z + HALF_WIDTH) do
					local block = getBlock(bx, by, bz)
					if not onGround and solid(block) then
						onGround, below = true, block
					end
				end
			end
		end
	end
	local inWater = swimmable(getBlock(floor(x), floor(y + 0.1), floor(z)))
		or swimmable(getBlock(floor(x), floor(y + 0.9), floor(z)))
	return onGround, inWater, below
end

--[[ Mining hits ]]

-- Ticks between hit sounds on the block being mined.
SoundRules.HIT_INTERVAL = 4

export type HitClock = { x: number, y: number, z: number, block: number, ticks: number }

function SoundRules.newHitClock(): HitClock
	return { x = math.huge, y = 0, z = 0, block = -1, ticks = 0 }
end

-- Mining starts over (a new block, or the button let go).
function SoundRules.resetHits(clock: HitClock)
	clock.x, clock.ticks = math.huge, 0
end

-- A tick spent hitting `block` at (x, y, z): true when its hit sound is due (the first tick on
-- a block, then every HIT_INTERVAL).
function SoundRules.hitTick(clock: HitClock, x: number, y: number, z: number, block: number): boolean
	if clock.x ~= x or clock.y ~= y or clock.z ~= z or clock.block ~= block then
		clock.x, clock.y, clock.z, clock.block, clock.ticks = x, y, z, block, 0
	end
	local due = clock.ticks % SoundRules.HIT_INTERVAL == 0
	clock.ticks += 1
	return due
end

--[[ Ambience ]]

--[[
	Chance per tick that a lit furnace crackles. Minecraft gives each lit furnace a 1 in 10 chance
	whenever the client's random display tick picks it, which for a furnace a block or two from
	the player is about 12% of ticks: a crackle every 4 seconds or so.
]]
SoundRules.CRACKLE_CHANCE = 0.012
-- Blocks from the listener within which a working machine that `crackles` is heard crackling
-- (Minecraft's animateTick reaches 16 blocks around the player).
SoundRules.CRACKLE_RANGE = 16
-- Machines that crackle like a lit furnace while they work (their Machines record says active).
local CRACKLING: { [string]: boolean } = {
	-- Mekanism Generators' Heat Generator, burning furnace fuel or lava.
	HeatGenerator = true,
	-- The Combustion Generator, burning fuel.
	CombustionGenerator = true,
}

-- Does the machine `block` crackle like a lit furnace while it works?
function SoundRules.crackles(block: number): boolean
	return Blocks.isValid(block) and CRACKLING[Blocks.get(block).name] == true
end

-- Caves: the rumble comes when the sky light reaching the camera is below CAVE_EXPOSURE, every
-- CAVE_MIN to CAVE_MAX seconds spent there (time above ground counts back down).
SoundRules.CAVE_EXPOSURE = 0.2
SoundRules.CAVE_MIN, SoundRules.CAVE_MAX = 90, 300

-- Seconds underground before the next cave rumble, for a random roll in [0, 1).
function SoundRules.caveDelay(roll: number): number
	return SoundRules.CAVE_MIN + (SoundRules.CAVE_MAX - SoundRules.CAVE_MIN) * roll
end

--[[
	Lava's sounds (LavaFluid.animateTick): Minecraft's client picks 667 random blocks a tick within
	16 blocks of the player (each axis nextInt(16) - nextInt(16)) and 667 within 32; lava with air
	above pops (block.lava.pop) one time in 100 and bubbles (block.lava.ambient) one in 200. Here
	LAVA_SAMPLES of each a tick stand for those 667, with the odds scaled to match: the same sounds
	on average for a twenty-eighth of the block reads.
]]
SoundRules.LAVA_SAMPLES = 24
SoundRules.LAVA_RANGES = table.freeze({ 16, 32 })
SoundRules.LAVA_POP = 1 / 100 * 667 / SoundRules.LAVA_SAMPLES
SoundRules.LAVA_AMBIENT = 1 / 200 * 667 / SoundRules.LAVA_SAMPLES

export type LavaSound = { sound: string, x: number, y: number, z: number, volume: number, pitch: number }

--[[
	One tick of lava sounds around block (x, y, z) (the listener's), with `random` rolls in [0, 1):
	the sounds due (positions in blocks; volume and pitch multiply the event's: Minecraft's
	0.2 + 0.2r and 0.9 + 0.15r). Lava (any level, CaveLava too) must have air above it.
]]
function SoundRules.lavaTick(getBlock: GetBlock, x: number, y: number, z: number, random: () -> number): { LavaSound }
	local found: { LavaSound } = {}
	local floor = math.floor
	for _, range in SoundRules.LAVA_RANGES do
		for _ = 1, SoundRules.LAVA_SAMPLES do
			local bx = x + floor(random() * range) - floor(random() * range)
			local by = y + floor(random() * range) - floor(random() * range)
			local bz = z + floor(random() * range) - floor(random() * range)
			local block = getBlock(bx, by, bz)
			if block and Fluids.ofBlock(block) == Fluids.LAVA then
				local above = getBlock(bx, by + 1, bz)
				if above == Blocks.AIR or above == Blocks.CAVE_AIR then
					if random() < SoundRules.LAVA_POP then
						table.insert(found, {
							sound = "block.lava.pop",
							x = bx + random(),
							y = by + 1,
							z = bz + random(),
							volume = 0.2 + random() * 0.2,
							pitch = 0.9 + random() * 0.15,
						})
					end
					if random() < SoundRules.LAVA_AMBIENT then
						table.insert(found, {
							sound = "block.lava.ambient",
							x = bx + 0.5,
							y = by + 0.5,
							z = bz + 0.5,
							volume = 0.2 + random() * 0.2,
							pitch = 0.9 + random() * 0.15,
						})
					end
				end
			end
		end
	end
	return found
end

return SoundRules
