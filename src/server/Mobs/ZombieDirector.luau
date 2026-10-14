--!strict
--!native
--[[
	The zombie apocalypse's director (pure; Mobs/Mobs runs it every tick after natural spawning):
	how many zombies each player has around them, blood moon hordes, and sending the surplus away.
	`mobs` is Config.Mobs (or a copy), `apoc` Config.Apocalypse.

	  Caps       a player's monster cap (MobSpawning's `context.hostileCap`):
	               normally  round(HostileCap x (1 at night, Zombies.DayFactor by day) x city),
	                         city = Zombies.CityFactor where the player stands in a city (the
	                         generator's cityAt 0.5 or more), else 1: 20 at night, 7 by day, 35
	                         and 12 in a city;
	               blood moon min(CapMax, round((CapBase + CapPerMoon x k) x city)), k the moon's
	                         number (Shared/Apocalypse/BloodMoon.number): 28, 32, 36... up to 60
	                         (49, 56, 60 in a city);
	               HostileCap 0 (Peaceful) makes every cap 0: no spawns and no waves.
	  Limits     the world's: Mobs.MaxMobs and MaxHostile (320, 200), or BloodMoon.MaxMobs and
	             MaxHostile (360, 260) while a blood moon is up; worked out again every tick from
	             the day time, never set at dusk and put back at dawn, so neither /time set nor a
	             restart in the middle of one can leave them raised.
	  Waves      while a blood moon is up (BloodMoon.active), at once and then every
	             BloodMoon.WaveInterval (600) ticks (never with Config.Mobs.Spawning false: the
	             void and the debug worlds, World/WorldInfo), for each living survival or
	             adventure player:
	             WaveBase + WavePerMoon x k zombies (8, 10, 12...), no more than their cap and the
	             world's room allow, in packs of 3-5 (MobSpawning.spawnPack) 28-44 blocks out, on
	             floors under the open sky in the chunks that tick (never inside a roofed base or a
	             bunker), the kinds by their `hordeWeight` grown by `hordeGrowth` x (k - 1) (runners
	             and brutes come more often each moon); each one hunts that player (MobAI `hunt`)
	             and is `persistent`. Natural monster spawning stops meanwhile (MobSpawning's
	             `hostilePaused`).
	  Hunts      every BloodMoon.HuntInterval (100) ticks of a blood moon, every zombie with no
	             target within Zombies.HuntRadius (44) of a living survival or adventure player
	             hunts the nearest such player.
	  Its end    when the blood moon sets (or /time set skips it), every hunt ends and a leave round
	             runs at once against the day's caps.
	  Leaving    leave rounds at dawn (night turning to day), at a blood moon's end and every
	             Zombies.Leave.Interval (600) ticks by day: for each living player who is not a
	             spectator, the zombies within LEAVE_RADIUS (32) blocks beyond their cap (the day's at
	             dawn and at the moon's end) that have no target in sight and break no block are sent
	             away (MobAI `leave` for Leave.Ticks), the furthest first. They walk off and go once
	             far enough and unseen (Mobs/MobWorld's despawning); a crowd round a shelter thins
	             out by day.
	  Noises     what zombies hear this tick (`hear`: Apocalypse/NoiseBus's noises, taken by
	             Mobs/Mobs): every radius times Noise.NightFactor (1.25) at night and RainFactor
	             (0.7) where it rains at the noise.
	With Config.Apocalypse.Enabled false the director does nothing and the caps are HostileCap.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local BloodMoon = require(Shared.Apocalypse.BloodMoon)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local GameMode = require(Shared.GameMode)

local MobAI = require(script.Parent.MobAI)
local MobSpawning = require(script.Parent.MobSpawning)
local MobWorld = require(script.Parent.MobWorld)

-- What the director reads of Config.Mobs and Config.Apocalypse (Spawning false: no waves).
export type MobSettings = { HostileCap: number, MaxHostile: number, MaxMobs: number, Spawning: boolean? }
export type Apocalypse = typeof(Config.Apocalypse)

export type Context = MobSpawning.Context

export type State = {
	tick: number,
	-- The blood moon and the day as they were last tick (nil: not seen yet).
	wasMoon: boolean,
	wasDay: boolean?,
	-- Ticks to the next wave and hunt round.
	waveTimer: number,
	huntTimer: number,
	-- (For specs and the debug screen.) Zombies the last wave brought, and sent away in all.
	lastWave: number,
	sentAway: number,
}

local ZombieDirector = {}

-- Zombies within this many blocks of a player count against their cap in a leave round.
ZombieDirector.LEAVE_RADIUS = 32
-- A wave's packs: 3-5 zombies, 28-44 blocks out, the floor looked for from WAVE_HEIGHT above the
-- player's feet down WAVE_SCAN cells, at most WAVE_TRIES packs a player.
ZombieDirector.PACK_MIN = 3
ZombieDirector.PACK_MAX = 5
ZombieDirector.WAVE_NEAR = 28
ZombieDirector.WAVE_FAR = 44
ZombieDirector.WAVE_HEIGHT = 24
ZombieDirector.WAVE_SCAN = 56
ZombieDirector.WAVE_TRIES = 8

local floor = math.floor
local CHUNK = ChunkLayout.SIZE

function ZombieDirector.new(): State
	return {
		tick = 0,
		wasMoon = false,
		wasDay = nil,
		waveTimer = 0,
		huntTimer = 0,
		lastWave = 0,
		sentAway = 0,
	}
end

-- Is a blood moon up at `dayTime`, and which one (k: 1, 2...; 0 when none)?
function ZombieDirector.moon(apoc: Apocalypse, dayTime: number): (boolean, number)
	if not apoc.Enabled or not BloodMoon.active(dayTime, apoc.BloodMoon) then
		return false, 0
	end
	return true, BloodMoon.number(DayCycle.day(dayTime), apoc.BloodMoon)
end

-- The world's limits at `dayTime` (see the header): maxMobs, MaxHostile.
function ZombieDirector.limits(mobs: MobSettings, apoc: Apocalypse, dayTime: number): (number, number)
	if ZombieDirector.moon(apoc, dayTime) then
		local s = apoc.BloodMoon
		return s.MaxMobs, s.MaxHostile
	end
	return mobs.MaxMobs, mobs.MaxHostile
end

--[[
	A player's monster cap (see the header): `city` is how much they stand in a city (cityAt, 0..1),
	`night` whether it is night, `moon` the blood moon's number (0: none). `day` asks for the day's
	cap whatever the time (a leave round at dawn or at a moon's end).
]]
function ZombieDirector.cap(mobs: MobSettings, apoc: Apocalypse, night: boolean, city: number, moon: number): number
	local base = mobs.HostileCap
	if base <= 0 then
		return 0
	end
	if not apoc.Enabled then
		return base
	end
	local Z = apoc.Zombies
	local factor = if city >= 0.5 then Z.CityFactor else 1
	if moon > 0 then
		local s = apoc.BloodMoon
		return math.min(s.CapMax, math.floor((s.CapBase + s.CapPerMoon * moon) * factor + 0.5))
	end
	return math.floor(base * (if night then 1 else Z.DayFactor) * factor + 0.5)
end

--[[
	This tick's `noises` as zombies hear them (see the header), changed in place and returned: `s`
	is Config.Apocalypse.Noise, `rainingAt` whether it rains at a cell (nil: never).
]]
function ZombieDirector.hear(
	noises: { MobAI.Noise },
	night: boolean,
	rainingAt: ((x: number, y: number, z: number) -> boolean)?,
	s: { NightFactor: number, RainFactor: number }
): { MobAI.Noise }
	for _, noise in noises do
		local factor = if night then s.NightFactor else 1
		if rainingAt and rainingAt(floor(noise.x), floor(noise.y), floor(noise.z)) then
			factor *= s.RainFactor
		end
		noise.radius *= factor
	end
	return noises
end

-- How much the player stands in a city (the context's cityAt; 0 without one).
local function cityOf(context: Context, player: MobWorld.PlayerView): number
	local cityAt = context.cityAt
	return if cityAt then cityAt(player.x, player.z) else 0
end

-- The cap of `player` now (see `cap`).
function ZombieDirector.capOf(
	mobs: MobSettings,
	apoc: Apocalypse,
	context: Context,
	player: MobWorld.PlayerView
): number
	local _, moon = ZombieDirector.moon(apoc, context.dayTime)
	return ZombieDirector.cap(mobs, apoc, not DayCycle.isDay(context.dayTime), cityOf(context, player), moon)
end

-- May zombies hunt this player (alive, survival or adventure)?
local function huntable(player: MobWorld.PlayerView): boolean
	return MobAI.attackable(player)
end

-- A zombie the director may give orders to: alive, ticking, not dying.
local function live(mob: MobWorld.Mob): boolean
	return mob.kind.zombie == true and not mob.removed and not mob.dead and not mob.frozen
end

-- Sends `mob` away (MobAI `leave`).
local function sendAway(state: State, apoc: Apocalypse, mob: MobWorld.Mob)
	local ai = mob.ai
	ai.leave = apoc.Zombies.Leave.Ticks
	ai.hunt = nil
	ai.target = nil
	ai.goal = "idle"
	ai.bx = nil
	-- (A shriek cut short: it walks off, not standing to finish it.)
	ai.scream = 0
	mob.persistent = false
	state.sentAway += 1
end

--[[
	A leave round (see the header): `dayCaps` asks for the day's caps whatever the time. Returns how
	many zombies it sent away.
]]
function ZombieDirector.leaveRound(
	world: MobWorld.MobWorld,
	state: State,
	context: Context,
	mobs: MobSettings,
	apoc: Apocalypse,
	dayCaps: boolean
): number
	local radius = ZombieDirector.LEAVE_RADIUS
	local limit = radius * radius
	local sent = 0
	for _, player in context.players do
		if not player.alive or GameMode.isSpectator(player.mode) then
			continue
		end
		local cap = if dayCaps
			then ZombieDirector.cap(mobs, apoc, false, cityOf(context, player), 0)
			else ZombieDirector.capOf(mobs, apoc, context, player)
		local around: { MobWorld.Mob } = {}
		local distances: { [MobWorld.Mob]: number } = {}
		for _, mob in world.order do
			if live(mob) and mob.ai.leave <= 0 then
				local body = mob.body
				local dx, dy, dz = body.x - player.x, body.y - player.y, body.z - player.z
				local d = dx * dx + dy * dy + dz * dz
				if d <= limit then
					table.insert(around, mob)
					distances[mob] = d
				end
			end
		end
		local excess = #around - cap
		if excess <= 0 then
			continue
		end
		-- (The furthest first.)
		table.sort(around, function(a: MobWorld.Mob, b: MobWorld.Mob): boolean
			local da, db = distances[a], distances[b]
			if da ~= db then
				return da > db
			end
			return a.id < b.id
		end)
		for _, mob in around do
			if excess <= 0 then
				break
			end
			local ai = mob.ai
			if not (ai.target ~= nil and ai.visible) and ai.bx == nil then
				sendAway(state, apoc, mob)
				excess -= 1
				sent += 1
			end
		end
	end
	return sent
end

-- Ends every hunt (the blood moon set).
local function endHunts(world: MobWorld.MobWorld)
	for _, mob in world.order do
		if mob.kind.zombie and not mob.removed then
			local ai = mob.ai
			if ai.hunt ~= nil then
				if ai.target == ai.hunt then
					-- (Still in sight: an ordinary chase, which forgets as ever.)
					ai.unseen = 0
				end
				ai.hunt = nil
				ai.progressTimer, ai.progressDistance = 0, -1
			end
			mob.persistent = false
		end
	end
end

-- Hunt assignment (see the header).
local function assignHunts(world: MobWorld.MobWorld, context: Context, apoc: Apocalypse)
	local radius = apoc.Zombies.HuntRadius
	local limit = radius * radius
	for _, mob in world.order do
		local ai = mob.ai
		if live(mob) and ai.leave <= 0 and ai.target == nil then
			local body = mob.body
			local best: MobWorld.PlayerView? = nil
			local bestDistance = limit
			for _, player in context.players do
				if huntable(player) then
					local dx, dy, dz = player.x - body.x, player.y - body.y, player.z - body.z
					local d = dx * dx + dy * dy + dz * dz
					if d <= bestDistance then
						best, bestDistance = player, d
					end
				end
			end
			if best and ai.hunt ~= best.key then
				ai.hunt = best.key
				ai.progressTimer, ai.progressDistance = 0, -1
				mob.persistent = true
			end
		end
	end
end

--[[
	A wave (see the header) for blood moon `moon`. Returns how many zombies it brought.
]]
function ZombieDirector.wave(
	world: MobWorld.MobWorld,
	context: Context,
	mobs: MobSettings,
	apoc: Apocalypse,
	moon: number
): number
	local s = apoc.BloodMoon
	local random = world.random
	local function nextInt(n: number): number
		return floor(random() * n)
	end
	local getBlock = world.getBlock
	local _, maxHostile = ZombieDirector.limits(mobs, apoc, context.dayTime)
	local totalHostile = MobSpawning.census(world)
	local brought = 0
	for _, player in context.players do
		if not huntable(player) then
			continue
		end
		local cap = ZombieDirector.capOf(mobs, apoc, context, player)
		local around = MobSpawning.census(world, player.x, player.y, player.z)
		local n = math.min(cap - around, maxHostile - totalHostile, s.WaveBase + s.WavePerMoon * moon)
		local tries = 0
		while n > 0 and tries < ZombieDirector.WAVE_TRIES do
			tries += 1
			if world.live >= world.options.maxMobs then
				return brought
			end
			local kind = MobSpawning.pickKind(true, random, "horde", moon)
			local size =
				math.min(ZombieDirector.PACK_MIN + nextInt(ZombieDirector.PACK_MAX - ZombieDirector.PACK_MIN + 1), n)
			local angle = random() * math.pi * 2
			local distance = ZombieDirector.WAVE_NEAR + random() * (ZombieDirector.WAVE_FAR - ZombieDirector.WAVE_NEAR)
			local cx = floor(player.x + math.cos(angle) * distance)
			local cz = floor(player.z + math.sin(angle) * distance)
			if not context.active(cx // CHUNK, cz // CHUNK) then
				continue
			end
			local cy = MobSpawning.findFloor(
				getBlock,
				kind,
				cx,
				floor(player.y) + ZombieDirector.WAVE_HEIGHT,
				cz,
				ZombieDirector.WAVE_SCAN
			)
			if cy == nil or context.skyOpen(cx, cy, cz) ~= true then
				continue
			end
			local ids = MobSpawning.spawnPack(world, context, kind, cx, cy, cz, size, nextInt, "wave")
			for _, id in ids do
				local mob = world:get(id)
				if mob then
					mob.ai.hunt = player.key
					mob.persistent = true
				end
			end
			n -= #ids
			totalHostile += #ids
			brought += #ids
		end
	end
	return brought
end

--[[
	One tick of the director (see the header), after natural spawning, with the tick's context.
	`mobSettings` and `apocalypse` default to Config.Mobs and Config.Apocalypse.
]]
function ZombieDirector.step(
	world: MobWorld.MobWorld,
	state: State,
	context: Context,
	mobSettings: MobSettings?,
	apocalypse: Apocalypse?
)
	local mobs: MobSettings = mobSettings or Config.Mobs
	local apoc: Apocalypse = apocalypse or Config.Apocalypse
	state.tick += 1
	if not apoc.Enabled then
		state.wasMoon, state.wasDay = false, nil
		return
	end
	local dayTime = context.dayTime
	local moonUp, moon = ZombieDirector.moon(apoc, dayTime)
	local day = DayCycle.isDay(dayTime)
	local leaveDone = false
	if state.wasMoon and not moonUp then
		-- The blood moon set: the hunts end, and the surplus is sent away.
		endHunts(world)
		ZombieDirector.leaveRound(world, state, context, mobs, apoc, true)
		leaveDone = true
	end
	if state.wasDay == false and day and not leaveDone then
		-- Dawn.
		ZombieDirector.leaveRound(world, state, context, mobs, apoc, true)
		leaveDone = true
	end
	if day and not leaveDone and state.tick % math.max(1, apoc.Zombies.Leave.Interval) == 0 then
		ZombieDirector.leaveRound(world, state, context, mobs, apoc, false)
	end
	if moonUp then
		state.waveTimer -= 1
		if state.waveTimer <= 0 then
			state.waveTimer = math.max(1, apoc.BloodMoon.WaveInterval)
			-- (No waves where nothing spawns: Config.Mobs.Spawning false, a world type without
			-- mobs: the void and the debug worlds.)
			state.lastWave = if mobs.Spawning == false then 0 else ZombieDirector.wave(world, context, mobs, apoc, moon)
		end
		state.huntTimer -= 1
		if state.huntTimer <= 0 then
			state.huntTimer = math.max(1, apoc.BloodMoon.HuntInterval)
			assignHunts(world, context, apoc)
		end
	else
		state.waveTimer, state.huntTimer = 0, 0
	end
	state.wasMoon, state.wasDay = moonUp, day
end

return ZombieDirector
