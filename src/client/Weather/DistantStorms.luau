--!strict
--!native
--[[
	Distant storms' lightning and rain, pure (Weather/StormView runs them, Weather/LightningView
	shows them; tests/spec/DistantStorms checks them). Minecraft has lightning only within about
	128 blocks of a player (ServerLevel.tickChunk in the chunks near one), heard and seen within
	160-256 (the bolt entity's tracking range), and no weather far off at all: it is one switch for
	the world. Here storms are regional (Shared/Weather) and their clouds are drawn out to the view
	distance (Weather/CloudLod), so their lightning is made here, on every client by itself, from
	the field: the same flashes on every client with nothing sent, as Minecraft 1.21.9 draws its
	End flashes from the game time alone (EndFlashState). The numbers are
	Config.Weather.Distant's.

	  Schedule  the world is cut into Cell-block cells and the server's clock
	            (workspace:GetServerTimeNow, which every client shares: not the weather clock,
	            which stands still under /gamerule doWeatherCycle false while the server goes on
	            striking) into Period-second periods. A period's flashes are worked out during the
	            one before, a band of rows a frame (`advance`, `budget`: the rows left shared out
	            over the frames left, so they are ready before the period starts at any frame rate
	            and no frame does it all). Its thunder is sampled at every cell centre within reach
	            of the camera (`prepare`, `fill`: Shared/Weather's grid at the period's start), and
	            each cell's chance in the period is its rate times the period's length with the
	            most thunder of it and its 8 neighbours (`bound`: a storm between two centres is
	            not missed), worked out as the rows come in; then a hash of (seed, cell, period)
	            rolls each cell (`roll`). A cell that fires draws its point, its time in the
	            period, its kind, its bolt's shape seed and flashes (1 to 3, as Minecraft's) from
	            more of the hash, and keeps the point with the share of the bound's weight the
	            thunder there has (thinning: the flashes follow the thunder at the point, not at
	            the cell's samples). `plan` does what is left of it at once.
	  Rate      Rate flashes a minute per km^2 of full thunder, from none at MinThunder (the
	            clouds' first tower step, CloudLod.buckets) up to Rate at 1 (`weight`). Measured on
	            seeds 12345, 777 and 4242 (1200 random places and times): 55% of the 2048-block
	            views hold thunder over MinThunder; of those the median holds 0.38 km^2 of full
	            thunder's weight (one in ten over 1.85, the most 6.9), so at Rate 12 a median storm
	            in view flashes every 13 s, one in ten more than 22 times a minute and the biggest
	            83 (more than PerMinute lets through); with a storm thundering (0.3 or more) 600
	            blocks off, 13 a minute on seed 12345 (the spec). Minecraft's own rate near a
	            player is 47 a minute per km^2, the server's here 233, real thunderstorms' 0.04 to
	            1. A sky busier than PerMinute in reach (one every 2.5 s) is thinned by one scale
	            for every cell (`roll`), which keeps the flashes with the lowest rolls: a client
	            allowed fewer (Fast clouds) sees some of the others', never different ones; with
	            another reach (another view distance, a phone) the scale differs too, so in a sky
	            that busy two clients share most of their flashes, not all.
	  Kinds     GroundShare are bolts to the ground (the US's in-cloud to ground ratio is about
	            2.6), only where rain falls (not snow, not a desert: Minecraft's lightning needs
	            isRainingAt); the rest flash inside the cloud. No bolt strikes within MinDistance
	            of the camera or anyone (a strike beside a player that burns nothing would look
	            wrong), nor within Lightning.Radius + Margin of a player who stands in thunder
	            (the server strikes there, for real: World/Lightning): those flash in the cloud
	            (`strikes`, asked as the flash shows: the players have moved since it was rolled).
	  Seen      out to the view distance (the clouds stop there). A bolt is drawn from the
	            ground (`groundAt`: the generator's height, its sea's surface over water) to the
	            cloud's base (`boltScale`), `boltWidth` wide: about two pixels at any distance
	            (Camera.FieldOfView 70 is the vertical angle: at 1080 lines a pixel at the centre
	            of the screen is 2 tan(35 deg) / 1080 = 1.3e-3 of the distance, PIXEL), and
	            `brightness` times as bright as it is (Beam.Brightness) where the Atmosphere's haze
	            would leave only a share of it (Rendering/AtmosphereModel: 10% at the view
	            distance). The sky's flash (`skyFlash`, for every strike, near ones too) is the
	            near one's (Config.Weather.Bolt.Flash, half at 512 blocks), by day down to DayFlash
	            of it from Near on (a distant flash is barely seen by day, it lights the horizon at
	            night; nearer, less of that, so it never jumps), and InCloudFlash of it for a flash
	            in the cloud.
	  Heard     out to Hearing blocks (thunder carries 15-25 km, a flash is seen 50-160: past it
	            the flashes are silent, as heat lightning), Shared/Weather.thunderDelay later:
	            `thunderVolume` half at HalfVolume and gone at Hearing (`thunderCue`: past Near
	            also what the near thunder's own voice loses THUNDER_OFFSET blocks off, `rolloff`,
	            so it is never louder just past Near), `thunderPitch` lower and longer far off,
	            `muffle` the equalizer's dB (the air takes the highs: 33 dB a km at 4 kHz, under 1
	            below 250 Hz), `echoes` a second roll far off.
	  Rain      `rainPoints` Rings x Directions points around the camera; `hiss` the loudest
	            rain among them (Minecraft's rain sound level, `rainLevel`, weighted by
	            1 / (1 + (r / Half)^2)) and where it comes from (shorter when it falls all
	            around); `hissVolume` fades it as the rain at the camera takes over (the near
	            rain sound, Weather/PrecipitationView), underground, and to Roofed of it under a
	            roof, where `hissMuffle` dulls it further (as Minecraft's rain on a roof is half as
	            loud and lower).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Weather = require(Shared.Weather)

local LightningBolt = require(script.Parent.LightningBolt)

local floor, max, min, exp = math.floor, math.max, math.min, math.exp
local clamp = math.clamp

export type Settings = {
	-- Cell (blocks) and period (seconds) of the schedule.
	cell: number,
	period: number,
	-- Flashes a second per block^2 at full thunder, from `minThunder` up.
	rate: number,
	minThunder: number,
	groundShare: number,
	-- Most flashes in a period within reach.
	perPeriod: number,
	-- Blocks: flashes are made within `reach` of the camera, seen within `view`, heard within
	-- `hearing`.
	reach: number,
	view: number,
	hearing: number,
	-- No bolt within `minDistance` of anyone, nor within `guard` of a player in thunder.
	minDistance: number,
	guard: number,
	-- Bolts drawn at once, flashes (bolts or in the cloud) shown at once, sounds at once.
	bolts: number,
	glows: number,
	voices: number,
}

-- A flash: when (server time, s), where (blocks), a bolt or in the cloud, its shape and flashes,
-- and the thunder where it is.
export type Event = {
	time: number,
	x: number,
	z: number,
	ground: boolean,
	seed: number,
	flashes: number,
	thunder: number,
}

--[[
	A period's flashes around the camera as they are worked out (`prepare`, then `advance` a frame at
	a time): cells gx0.. x gz0.. around (x, z) (blocks), 3 bytes a cell (Field.grid's:
	precipitation, thunder, cover x 255), `filled` rows of `rows` sampled so far; each inner cell's
	bound (`bounds`, a thunder byte: the most of it and its 8 neighbours, 0 out of reach) known up
	to row `bounded`, their chances in reach adding up to `expected` flashes in the period (`chances`
	by thunder byte), thinned by `scale` to the cap; `rolled` inner rows rolled into `events`, which
	are in time order once it is `ready`, as it is due to be by server time `due` (set by `budget`
	as its work starts; -1 before).
]]
export type Grid = {
	period: number,
	x: number,
	z: number,
	gx0: number,
	gz0: number,
	cols: number,
	rows: number,
	filled: number,
	bounded: number,
	rolled: number,
	expected: number,
	scale: number,
	ready: boolean,
	due: number,
	data: buffer,
	bounds: buffer,
	chances: { number },
	events: { Event },
}

-- Samples the weather at `cols` x `rows` points from (x0, z0), `step` apart (Field.grid).
export type Sampler = (x0: number, z0: number, step: number, cols: number, rows: number) -> buffer

export type Checks = {
	-- The thunder (0..1) at (x, z) at the period's moment.
	thunder: (x: number, z: number) -> number,
	-- Does rain fall at (x, z) (not snow, not a dry biome)?
	rains: (x: number, z: number) -> boolean,
}

-- A point the distant rain is listened for at, and its weight.
export type Point = { dx: number, dz: number, distance: number, weight: number }

local DistantStorms = {}

-- The Clouds setting's Fast (CloudLod.FAST).
local FAST = 1
-- A pixel's share of the distance at the centre of the screen, Camera.FieldOfView 70 (vertical) and
-- 1080 lines: 2 tan(35 deg) / 1080.
DistantStorms.PIXEL = 2 * math.tan(math.rad(35)) / 1080
-- How far from the listener a near strike's thunder plays (blocks), towards the strike
-- (Weather/LightningView; Minecraft plays a sound heard everywhere 2 blocks off that way).
DistantStorms.THUNDER_OFFSET = 8
-- Where the rolls come from (salts of the world seed).
local ROLL = Hash.string("distant lightning")
local DRAW = Hash.string("distant lightning draw")
-- A cell's sample reaches this share of its size from its centre (half its diagonal).
local CORNER = 0.71
-- Shares of a period: a grid is due SLACK of one before its period starts (frames come unevenly),
-- and one whose work starts with less time left than that (late) gets CATCH_UP of one, so no
-- frame does it all (`budget`).
local SLACK = 0.25
local CATCH_UP = 0.25

--[[
	The settings for the Clouds setting `mode` (Fast: fewer flashes and bolts), a view of `view`
	blocks, on a phone or not (`mobile`: nearer hearing, fewer sounds).
]]
function DistantStorms.settings(mode: number, view: number, mobile: boolean?): Settings
	local distant = Config.Weather.Distant
	local fast = mode <= FAST
	local hearing = if mobile then distant.MobileHearing else distant.Hearing
	local reach = min(max(view, hearing), distant.MaxReach)
	return {
		cell = distant.Cell,
		period = distant.Period,
		rate = distant.Rate / 60 / 1e6,
		minThunder = distant.MinThunder,
		groundShare = distant.GroundShare,
		perPeriod = (if fast then distant.FastPerMinute else distant.PerMinute) * distant.Period / 60,
		reach = reach,
		view = min(view, reach),
		hearing = min(hearing, reach),
		minDistance = distant.MinDistance,
		guard = Config.Weather.Lightning.Radius + distant.Margin,
		bolts = if fast then distant.FastBolts else distant.Bolts,
		glows = distant.Glows,
		voices = if mobile then distant.MobileVoices else distant.Voices,
	}
end

--[[ Schedule ]]

-- How much thunder `thunder` counts for the rate: 0 up to `minThunder`, 1 at full thunder.
function DistantStorms.weight(settings: Settings, thunder: number): number
	local low = settings.minThunder
	return clamp((thunder - low) / (1 - low), 0, 1)
end

-- A cell's chance of a flash in one period with thunder `thunder` (Poisson: at least one).
function DistantStorms.chance(settings: Settings, thunder: number): number
	local cell = settings.cell
	return 1 - exp(-settings.rate * cell * cell * settings.period * DistantStorms.weight(settings, thunder))
end

function DistantStorms.newGrid(): Grid
	return {
		period = -1,
		x = 0,
		z = 0,
		gx0 = 0,
		gz0 = 0,
		cols = 0,
		rows = 0,
		filled = 0,
		bounded = 0,
		rolled = 0,
		expected = 0,
		scale = 0,
		ready = false,
		due = -1,
		data = buffer.create(0),
		bounds = buffer.create(0),
		chances = table.create(256, 0),
		events = {},
	}
end

--[[
	Sets `grid` up for period `period` around the camera at (x, z) (blocks): every cell whose
	centre can be within reach, and a ring around them (their neighbours). Nothing is sampled yet.
]]
function DistantStorms.prepare(grid: Grid, settings: Settings, period: number, x: number, z: number)
	local cell, reach = settings.cell, settings.reach
	local gx0, gz0 = floor((x - reach) / cell) - 1, floor((z - reach) / cell) - 1
	local cols = floor((x + reach) / cell) + 1 - gx0 + 1
	local rows = floor((z + reach) / cell) + 1 - gz0 + 1
	if buffer.len(grid.data) < cols * rows * 3 then
		grid.data = buffer.create(cols * rows * 3)
	end
	if buffer.len(grid.bounds) < cols * rows then
		grid.bounds = buffer.create(cols * rows)
	end
	grid.period, grid.x, grid.z = period, x, z
	grid.gx0, grid.gz0, grid.cols, grid.rows = gx0, gz0, cols, rows
	grid.filled, grid.bounded, grid.rolled, grid.expected, grid.scale, grid.ready = 0, 0, 0, 0, 0, false
	grid.due = -1
	table.clear(grid.events)
	local chances = grid.chances
	for value = 0, 255 do
		chances[value + 1] = DistantStorms.chance(settings, value / 255)
	end
end

-- The bounds of `grid`'s inner rows up to `last` (their neighbours are sampled), and their cells'
-- chances in reach added to `expected` (of the cells whose centre is in reach: as many as the
-- reach's disc holds).
local function boundRows(grid: Grid, settings: Settings, last: number)
	local cell, reach = settings.cell, settings.reach
	local within = reach + cell * CORNER
	local cols, data, bounds, chances = grid.cols, grid.data, grid.bounds, grid.chances
	local stride = cols * 3
	local expected = grid.expected
	for row = grid.bounded + 1, last do
		local cz = (grid.gz0 + row + 0.5) * cell - grid.z
		for col = 1, cols - 2 do
			local cx = (grid.gx0 + col + 0.5) * cell - grid.x
			local d2 = cx * cx + cz * cz
			local most = 0
			-- (Every cell part of which is in reach: the points beyond it are dropped by `roll`.)
			if d2 <= within * within then
				-- (DistantStorms.bound, inside the grid's ring.)
				local index = (row * cols + col) * 3 + 1
				for at = index - stride, index + stride, stride do
					most = max(most, buffer.readu8(data, at - 3), buffer.readu8(data, at), buffer.readu8(data, at + 3))
				end
				if d2 <= reach * reach then
					expected += chances[most + 1]
				end
			end
			buffer.writeu8(bounds, row * cols + col, most)
		end
	end
	grid.expected = expected
	grid.bounded = max(grid.bounded, last)
end

--[[
	Samples about `budget` more cells of `grid` (whole rows, at least one, one call of `sample`),
	and works out the bounds of the rows whose neighbours are all in. Returns whether it is all
	sampled.
]]
function DistantStorms.fill(grid: Grid, settings: Settings, sample: Sampler, budget: number): boolean
	local cols, cell = grid.cols, settings.cell
	local count = min(max(1, budget // max(cols, 1)), grid.rows - grid.filled)
	if count > 0 then
		local out = sample((grid.gx0 + 0.5) * cell, (grid.gz0 + grid.filled + 0.5) * cell, cell, cols, count)
		buffer.copy(grid.data, grid.filled * cols * 3, out, 0, count * cols * 3)
		grid.filled += count
		boundRows(grid, settings, min(grid.filled - 2, grid.rows - 2))
	end
	return grid.filled >= grid.rows
end

-- The thunder byte of the grid's cell (col, row) (0 outside it).
local function thunderByte(grid: Grid, col: number, row: number): number
	if col < 0 or row < 0 or col >= grid.cols or row >= grid.rows then
		return 0
	end
	return buffer.readu8(grid.data, (row * grid.cols + col) * 3 + 1)
end

-- The most thunder (0..1) of the grid's cell (col, row) and its 8 neighbours.
function DistantStorms.bound(grid: Grid, col: number, row: number): number
	local most = 0
	for dr = -1, 1 do
		for dc = -1, 1 do
			local value = thunderByte(grid, col + dc, row + dr)
			if value > most then
				most = value
			end
		end
	end
	return most / 255
end

local function byTime(a: Event, b: Event): boolean
	return a.time < b.time
end

--[[
	Rolls about `budget` more cells of `grid` (whole inner rows, at least one) once it is all
	sampled, in world `seed`: a cell fires when the hash of (seed, cell, period) is under its chance
	(by its bound) times `scale`, the one thinning for all cells that keeps the expected flashes
	within the cap. A flash is kept where `checks` say so (see the header); the last row puts them in
	time order and makes the grid `ready`. Returns whether it is.
]]
function DistantStorms.roll(grid: Grid, settings: Settings, seed: number, checks: Checks, budget: number): boolean
	if grid.ready or grid.period < 0 or grid.filled < grid.rows then
		return grid.ready
	end
	local last = grid.rows - 2
	local cols = grid.cols
	local count = last - grid.rolled
	-- (A clear sky, the usual case, is done at once: nothing to roll.)
	if grid.expected > 0 then
		if grid.rolled == 0 then
			grid.scale = min(1, settings.perPeriod / grid.expected)
		end
		count = min(max(1, budget // max(cols, 1)), count)
		local cell, reach = settings.cell, settings.reach
		local least = floor(settings.minThunder * 255)
		local scale, period, chances, bounds = grid.scale, grid.period, grid.chances, grid.bounds
		local rollKey, drawKey = Hash.hash3(seed, ROLL, 0, 0), Hash.hash3(seed, DRAW, 0, 0)
		for row = grid.rolled + 1, grid.rolled + count do
			for col = 1, cols - 2 do
				local most = buffer.readu8(bounds, row * cols + col)
				if most <= least then
					continue
				end
				local bound = most / 255
				local gx, gz = grid.gx0 + col, grid.gz0 + row
				if Hash.float3(rollKey, gx, gz, period) >= chances[most + 1] * scale then
					continue
				end
				-- (Every draw is made, in this order, whatever is kept: the same on every client.)
				local rng = Hash.rng(Hash.hash3(drawKey, gx, gz, period))
				local px, pz = (gx + rng:float()) * cell, (gz + rng:float()) * cell
				local offset = rng:float() * settings.period
				local ground = rng:float() < settings.groundShare
				local shape = rng:next()
				local flashes = 1 + rng:next() % 3
				local keep = rng:float()
				local dx, dz = px - grid.x, pz - grid.z
				if dx * dx + dz * dz > reach * reach then
					continue
				end
				local thunder = checks.thunder(px, pz)
				local share = DistantStorms.weight(settings, thunder) / DistantStorms.weight(settings, bound)
				if keep >= share then
					continue
				end
				table.insert(grid.events, {
					time = period * settings.period + offset,
					x = px,
					z = pz,
					ground = ground and checks.rains(px, pz),
					seed = shape,
					flashes = flashes,
					thunder = thunder,
				})
			end
		end
	end
	grid.rolled += count
	if grid.rolled >= last then
		table.sort(grid.events, byTime)
		grid.ready = true
	end
	return grid.ready
end

--[[
	One frame's work on `grid` (prepared): about `budget` cells (whole rows, at least one) sampled
	while it is not all sampled, and what is left of them rolled. Returns whether it is ready (its
	`events` planned).
]]
function DistantStorms.advance(
	grid: Grid,
	settings: Settings,
	sample: Sampler,
	seed: number,
	checks: Checks,
	budget: number
): boolean
	local cols = max(grid.cols, 1)
	local rows = max(1, budget // cols)
	if grid.filled < grid.rows then
		local count = min(rows, grid.rows - grid.filled)
		DistantStorms.fill(grid, settings, sample, count * cols)
		rows -= count
		if rows <= 0 then
			return false
		end
	end
	return DistantStorms.roll(grid, settings, seed, checks, rows * cols)
end

--[[
	The cells to `advance` `grid` by this frame, server time `now`, frames `frameTime` seconds
	apart: its rows of work left (sampling them, then rolling them) shared out over the frames left
	until it is `due`, whole rows, at least CellsPerFrame. It is due SLACK of a period before its
	period starts, or, when its work starts later than CATCH_UP of a period before that (late: the
	weather or the settings changed, the game started), CATCH_UP of a period after it starts.
]]
function DistantStorms.budget(grid: Grid, settings: Settings, frameTime: number, now: number): number
	if grid.due < 0 then
		local start = grid.period * settings.period
		grid.due = max(start - settings.period * SLACK, now + settings.period * CATCH_UP)
	end
	local rows = (grid.rows - grid.filled) + max(grid.rows - 2 - grid.rolled, 0)
	-- (This frame and those until it is due; a hair over for the rounding of the times.)
	local frames = max(1, 1 + floor((grid.due - now) / max(frameTime, 1e-3) + 1e-6))
	local perFrame = (rows + frames - 1) // frames
	return max(perFrame * grid.cols, Config.Weather.Distant.CellsPerFrame)
end

-- The flashes a minute `grid`'s chances add up to, after the cap (F3).
function DistantStorms.perMinute(settings: Settings, grid: Grid): number
	return min(grid.expected, settings.perPeriod) * 60 / settings.period
end

--[[
	Finishes `grid` (all sampled) at once and copies its flashes into `out` (cleared; in time
	order). Returns how many, and the flashes a minute expected (`perMinute`).
]]
function DistantStorms.plan(
	settings: Settings,
	grid: Grid,
	seed: number,
	checks: Checks,
	out: { Event }
): (number, number)
	table.clear(out)
	if grid.period < 0 or grid.filled < grid.rows then
		return 0, 0
	end
	DistantStorms.roll(grid, settings, seed, checks, math.huge)
	table.move(grid.events, 1, #grid.events, 1, out)
	return #out, DistantStorms.perMinute(settings, grid)
end

--[[
	Whether flash `event` strikes the ground as it shows with the camera at (x, z): a bolt where
	rain falls (`event.ground`), not within MinDistance of the camera nor where `guarded` says a
	player is near (the server strikes there); else it flashes in the cloud. (Asked as it shows,
	not as it is rolled: the players have moved since.)
]]
function DistantStorms.strikes(
	settings: Settings,
	event: Event,
	x: number,
	z: number,
	guarded: (x: number, z: number) -> boolean
): boolean
	if not event.ground then
		return false
	end
	local dx, dz = event.x - x, event.z - z
	if dx * dx + dz * dz < settings.minDistance * settings.minDistance then
		return false
	end
	return not guarded(event.x, event.z)
end

--[[ Seen ]]

--[[
	The height (blocks) a bolt to the ground stands on in a column whose natural ground is
	`height` (the generator's `column`): the sea's surface over water, `seaLevel` (the generator's
	own: 64 for the default world, 0 for a flat one without a sea; nil: Config.SeaLevel).
]]
function DistantStorms.groundAt(height: number, seaLevel: number?): number
	return max(height, seaLevel or Config.SeaLevel)
end

-- The width (blocks) a bolt `distance` blocks away is drawn: Minecraft's (LightningBolt.WIDTH)
-- near, about two pixels far.
function DistantStorms.boltWidth(distance: number): number
	return max(LightningBolt.WIDTH, Config.Weather.Distant.PixelWidth * max(distance, 0))
end

-- How much taller than Minecraft's (LightningBolt.HEIGHT) a bolt from `ground` to a cloud base at
-- `base` is drawn (from half to three times).
function DistantStorms.boltScale(ground: number, base: number): number
	return clamp((base - ground) / LightningBolt.HEIGHT, 0.5, 3)
end

-- The brightness (Beam.Brightness) that shows a bolt where the haze lets `transmittance` (0..1)
-- of its light through as bright as near: 1 / transmittance, at most MaxBrightness.
function DistantStorms.brightness(transmittance: number): number
	local most = Config.Weather.Distant.MaxBrightness
	return clamp(1 / max(transmittance, 1 / most), 1, most)
end

--[[
	The share of Config.Weather.Bolt.Flash a strike or flash `distance` blocks away brightens the
	picture by: half at 512 blocks, in full daylight (`daylight` 1: DayCycle.skyBrightness) less,
	down to DayFlash of it from Distant.Near on (all of it at the strike: the near and the distant
	ones' flashes meet at Near), and InCloudFlash of it for a flash inside the cloud (`ground`
	false).
]]
function DistantStorms.skyFlash(distance: number, ground: boolean, daylight: number): number
	local distant = Config.Weather.Distant
	local d = max(distance, 0)
	local day = clamp(daylight, 0, 1) * clamp(d / distant.Near, 0, 1)
	local byDay = 1 - (1 - distant.DayFlash) * day
	local kind = if ground then 1 else distant.InCloudFlash
	return 1 / (1 + d / 512) * kind * byDay
end

--[[ Heard ]]

-- 0 below `from`, 1 above `to`, smooth between.
local function smoothstep(from: number, to: number, value: number): number
	local t = clamp((value - from) / (to - from), 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	The cue volume of thunder `distance` blocks away heard as far as `hearing`: 1 / (1 + (d /
	HalfVolume)^2), fading out over the last quarter of the hearing (0 beyond).
]]
function DistantStorms.thunderVolume(distance: number, hearing: number): number
	local d = max(distance, 0)
	local ratio = d / Config.Weather.Distant.HalfVolume
	return 1 / (1 + ratio * ratio) * (1 - smoothstep(hearing * 0.75, hearing, d))
end

--[[
	The share of a positioned sound's volume Roblox's Linear roll-off leaves `distance` blocks from
	the listener when it is heard within `range` blocks (Audio/SoundPlayer: all of it within
	Config.Sounds.MinDistance, none at the range).
]]
function DistantStorms.rolloff(distance: number, range: number): number
	local full = min(Config.Sounds.MinDistance, range)
	if distance <= full then
		return 1
	end
	if distance >= range then
		return 0
	end
	return 1 - (distance - full) / (range - full)
end

--[[
	The cue volume thunder `distance` blocks away plays at: `thunderVolume`. A near one (within
	Distant.Near) plays THUNDER_OFFSET blocks off on a voice heard within `nearRange` blocks, which
	keeps `rolloff` of it; a far one plays on a distant voice heard whole, so it is given that share
	too: thunder is never louder just past Near than just within it.
]]
function DistantStorms.thunderCue(distance: number, hearing: number, nearRange: number): number
	local volume = DistantStorms.thunderVolume(distance, hearing)
	if distance > Config.Weather.Distant.Near then
		volume *= DistantStorms.rolloff(DistantStorms.THUNDER_OFFSET, nearRange)
	end
	return volume
end

-- The pitch the thunder plays at (times the event's): up to Deepen lower at the hearing's edge
-- (so slower, and longer).
function DistantStorms.thunderPitch(distance: number, hearing: number): number
	return 1 - Config.Weather.Distant.Deepen * clamp(distance / max(hearing, 1), 0, 1)
end

--[[
	The equalizer's gains (dB: low, mid, high; EqualizerSoundEffect) for thunder `distance` blocks
	away: nothing within Near, then the highs and mids lose High and Mid dB every 256 blocks (down
	to HighFloor and MidFloor) and the lows gain up to Low by 1024: a distant rumble with no crack.
]]
function DistantStorms.muffle(distance: number): (number, number, number)
	local distant = Config.Weather.Distant
	local past = max(distance - distant.Near, 0) / 256
	local low = distant.Low * clamp(distance / 1024, 0, 1)
	return low, -min(distant.Mid * past, distant.MidFloor), -min(distant.High * past, distant.HighFloor)
end

-- How many echoes roll after the thunder (0 within Echo.From, then 1).
function DistantStorms.echoes(distance: number): number
	return if distance >= Config.Weather.Distant.Echo.From then 1 else 0
end

--[[ Rain ]]

--[[
	The points the distant rain is listened for at: Rain.Directions around each of Rain.Rings
	(blocks), every other ring turned by half a step, each with its weight 1 / (1 + (r / Half)^2).
]]
function DistantStorms.rainPoints(): { Point }
	local rain = Config.Weather.Distant.Rain
	local points: { Point } = {}
	for ring, radius in rain.Rings do
		for i = 0, rain.Directions - 1 do
			local angle = (i + (ring % 2) * 0.5) / rain.Directions * 2 * math.pi
			local ratio = radius / rain.Half
			table.insert(points, {
				dx = math.cos(angle) * radius,
				dz = math.sin(angle) * radius,
				distance = radius,
				weight = 1 / (1 + ratio * ratio),
			})
		end
	end
	return points
end

-- How loud rain with precipitation `precipitation` is (0..1): Minecraft's rain sound level
-- (Shared/Weather.rainSound's, 0 until it rains).
function DistantStorms.rainLevel(precipitation: number): number
	if precipitation <= Weather.RAINING then
		return 0
	end
	return clamp(precipitation / 0.5, 0, 1)
end

--[[
	The distant rain at `points`: the loudest, weighted (0..1), and where it comes from (a
	direction (dx, dz) whose length is 1 when it all comes from one side, shorter when it falls
	all around). `level(dx, dz)` is the rain level at that offset from the camera (rainLevel; 0
	for snow or a dry biome).
]]
function DistantStorms.hiss(points: { Point }, level: (dx: number, dz: number) -> number): (number, number, number)
	local loudest, total, vx, vz = 0, 0, 0, 0
	for _, point in points do
		local value = level(point.dx, point.dz)
		if value > 0 then
			local weighted = value * point.weight
			loudest = max(loudest, weighted)
			total += weighted
			vx += weighted * point.dx / point.distance
			vz += weighted * point.dz / point.distance
		end
	end
	if total <= 0 then
		return 0, 0, 0
	end
	return loudest, vx / total, vz / total
end

--[[
	The distant rain's cue volume: Rain.Volume at `level`, less as the rain falling at the camera
	(`near`, its precipitation where it rains there, 0 otherwise) is heard by itself (rainLevel),
	underground (`exposure`: the sky exposure, Rendering/LightingController) and under a roof
	(`roof`: 0 in the open, 1 under a block that stops rain, smoothed between): Rain.Roofed of it.
]]
function DistantStorms.hissVolume(level: number, near: number, exposure: number, roof: number): number
	local rain = Config.Weather.Distant.Rain
	local takenOver = DistantStorms.rainLevel(near)
	local roofed = 1 - (1 - rain.Roofed) * clamp(roof, 0, 1)
	return rain.Volume * clamp(level, 0, 1) * (1 - takenOver) * clamp(exposure, 0, 1) * roofed
end

-- The distant rain's equalizer gains (dB: low, mid, high): Rain.Muffle in the open, towards
-- Rain.RoofMuffle under a roof (`roof`, as hissVolume's).
function DistantStorms.hissMuffle(roof: number): (number, number, number)
	local rain = Config.Weather.Distant.Rain
	local open, under = rain.Muffle, rain.RoofMuffle
	local t = clamp(roof, 0, 1)
	return open.Low + (under.Low - open.Low) * t,
		open.Mid + (under.Mid - open.Mid) * t,
		open.High + (under.High - open.High) * t
end

return DistantStorms
