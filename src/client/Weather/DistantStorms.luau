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
	            striking) into Period-second periods. A period's thunder is sampled at every cell
	            centre within reach of the camera before it starts (`prepare`, `fill`: Shared/
	            Weather's grid at the period's start, a band of rows a frame). A cell's chance in
	            the period is its rate times the period's length with the most thunder of it and
	            its 8 neighbours (`bound`: a storm between two centres is not missed); a hash of
	            (seed, cell, period) rolls it (`plan`). A cell that fires draws its point, its time
	            in the period, its kind, its bolt's shape seed and flashes (1 to 3, as Minecraft's)
	            from more of the hash, and keeps the point with the share of the bound's weight
	            the thunder there has (thinning: the flashes follow the thunder at the point, not
	            at the cell's samples).
	  Rate      Rate flashes a minute per km^2 of full thunder, from none at MinThunder (the
	            clouds' first tower step, CloudLod.buckets) up to Rate at 1 (`weight`). Measured on
	            seeds 12345, 777 and 4242 (1200 random places and times): 55% of the 2048-block
	            views hold thunder over MinThunder; of those the median holds 0.38 km^2 of full
	            thunder's weight (one in ten over 1.85, the most 6.9), so at Rate 12 a median storm
	            in view flashes every 13 s and a big one twice a second; with a storm thundering
	            (0.3 or more) 600 blocks off, 13 a minute on seed 12345 (the spec). Minecraft's own
	            rate near a player is 47 a minute per km^2, the server's here 233, real
	            thunderstorms' 0.04 to 1. A sky busier than PerMinute in reach is thinned by one
	            scale for every cell
	            (`plan`), which keeps the flashes with the lowest rolls: a client allowed fewer
	            (Fast clouds) sees some of the others', never different ones.
	  Kinds     GroundShare are bolts to the ground (the US's in-cloud to ground ratio is about
	            2.6), only where rain falls (not snow, not a desert: Minecraft's lightning needs
	            isRainingAt); the rest flash inside the cloud. No bolt strikes within MinDistance
	            of the camera or anyone (a strike beside a player that burns nothing would look
	            wrong), nor within Lightning.Radius + Margin of a player who stands in thunder
	            (the server strikes there, for real: World/Lightning): those flash in the cloud.
	  Seen      out to the view distance (the clouds stop there). A bolt is drawn from the
	            ground to the cloud's base (`boltScale`), `boltWidth` wide: about two pixels at
	            any distance (Camera.FieldOfView 70 at 1080 lines: a pixel is 1.13e-3 of the
	            distance), and `brightness` times as bright as it is (Beam.Brightness) where the
	            Atmosphere's haze would leave only a share of it (Rendering/AtmosphereModel: 10% at
	            the view distance). The sky's flash (`skyFlash`) is the near one's (Config.Weather
	            .Bolt.Flash, half at 512 blocks), then DayFlash of it by day (a distant flash is
	            barely seen by day, it lights the horizon at night) and InCloudFlash of it for a
	            flash in the cloud.
	  Heard     out to Hearing blocks (thunder carries 15-25 km, a flash is seen 50-160: past it
	            the flashes are silent, as heat lightning), Shared/Weather.thunderDelay later:
	            `thunderVolume` half at HalfVolume and gone at Hearing, `thunderPitch` lower and
	            longer far off, `muffle` the equalizer's dB (the air takes the highs: 33 dB a km
	            at 4 kHz, under 1 below 250 Hz), `echoes` a second roll far off.
	  Rain      `rainPoints` Rings x Directions points around the camera; `hiss` the loudest
	            rain among them (Minecraft's rain sound level, `rainLevel`, weighted by
	            1 / (1 + (r / Half)^2)) and where it comes from (shorter when it falls all
	            around); `hissVolume` fades it as the rain at the camera takes over (the near
	            rain sound, Weather/PrecipitationView) and indoors.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Weather = require(Shared.Weather)

local LightningBolt = require(script.Parent.LightningBolt)

local floor, max, min, sqrt, exp = math.floor, math.max, math.min, math.sqrt, math.exp
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

-- A period's thunder around the camera: cells gx0.. x gz0.., 3 bytes a cell (Field.grid's:
-- precipitation, thunder, cover x 255), `filled` rows of `rows` sampled so far.
export type Grid = {
	period: number,
	gx0: number,
	gz0: number,
	cols: number,
	rows: number,
	filled: number,
	data: buffer,
}

-- Samples the weather at `cols` x `rows` points from (x0, z0), `step` apart (Field.grid).
export type Sampler = (x0: number, z0: number, step: number, cols: number, rows: number) -> buffer

export type Checks = {
	-- The thunder (0..1) at (x, z) at the period's moment.
	thunder: (x: number, z: number) -> number,
	-- Does rain fall at (x, z) (not snow, not a dry biome)?
	rains: (x: number, z: number) -> boolean,
	-- Must no bolt strike at (x, z) (a player is near)?
	guarded: (x: number, z: number) -> boolean,
}

-- A point the distant rain is listened for at, and its weight.
export type Point = { dx: number, dz: number, distance: number, weight: number }

local DistantStorms = {}

-- The Clouds setting's Fast (CloudLod.FAST).
local FAST = 1
-- A pixel's share of the distance at Camera.FieldOfView 70 and 1080 lines (tan(35 deg) x 2 / 1080).
DistantStorms.PIXEL = 1.13e-3
-- Where the rolls come from (salts of the world seed).
local ROLL = Hash.string("distant lightning")
local DRAW = Hash.string("distant lightning draw")
-- A cell's sample reaches this share of its size from its centre (half its diagonal).
local CORNER = 0.71
-- (`plan`'s scratch: each cell's bound, a thunder byte, and the chance of each byte.)
local bounds = buffer.create(0)
local chances: { number } = table.create(256, 0)

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
	return { period = -1, gx0 = 0, gz0 = 0, cols = 0, rows = 0, filled = 0, data = buffer.create(0) }
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
	grid.period, grid.gx0, grid.gz0, grid.cols, grid.rows, grid.filled = period, gx0, gz0, cols, rows, 0
end

--[[
	Samples about `budget` more cells of `grid` (whole rows, one call of `sample`). Returns
	whether the grid is complete.
]]
function DistantStorms.fill(grid: Grid, settings: Settings, sample: Sampler, budget: number): boolean
	local cols, cell = grid.cols, settings.cell
	local count = min(max(1, budget // max(cols, 1)), grid.rows - grid.filled)
	if count > 0 then
		local out = sample((grid.gx0 + 0.5) * cell, (grid.gz0 + grid.filled + 0.5) * cell, cell, cols, count)
		buffer.copy(grid.data, grid.filled * cols * 3, out, 0, count * cols * 3)
		grid.filled += count
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

--[[
	The flashes of `grid`'s period around the camera at (x, z) (blocks) in world `seed`, into
	`out` (cleared; in time order). `checks` look at the points (see Checks). Returns how many,
	and the flashes a minute the cells' chances add up to (after the PerMinute cap).
]]
function DistantStorms.plan(
	settings: Settings,
	grid: Grid,
	seed: number,
	x: number,
	z: number,
	checks: Checks,
	out: { Event }
): (number, number)
	table.clear(out)
	if grid.period < 0 or grid.filled < grid.rows then
		return 0, 0
	end
	local cell, reach = settings.cell, settings.reach
	-- (Clear skies, the usual case, end here: one read a cell.)
	local least = floor(settings.minThunder * 255)
	local any = false
	for index = 1, grid.cols * grid.rows * 3 - 1, 3 do
		if buffer.readu8(grid.data, index) > least then
			any = true
			break
		end
	end
	if not any then
		return 0, 0
	end
	local within = reach + cell * CORNER
	local cols = grid.cols
	-- Each cell's bound (a thunder byte; 0 out of reach), and its chance by byte.
	if buffer.len(bounds) < cols * grid.rows then
		bounds = buffer.create(cols * grid.rows)
	end
	for value = 0, 255 do
		chances[value + 1] = DistantStorms.chance(settings, value / 255)
	end
	-- The chances add up to how many flashes the period expects (of the cells whose centre is in
	-- reach: as many as the reach's disc holds); over the cap, all are thinned alike.
	local expected = 0
	local data = grid.data
	local stride = cols * 3
	for row = 1, grid.rows - 2 do
		local cz = (grid.gz0 + row + 0.5) * cell - z
		for col = 1, cols - 2 do
			local cx = (grid.gx0 + col + 0.5) * cell - x
			local d2 = cx * cx + cz * cz
			local most = 0
			-- (Every cell part of which is in reach: the points beyond it are dropped below.)
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
	if expected <= 0 then
		return 0, 0
	end
	local scale = min(1, settings.perPeriod / expected)
	local period = grid.period
	local rollKey, drawKey = Hash.hash3(seed, ROLL, 0, 0), Hash.hash3(seed, DRAW, 0, 0)
	for row = 1, grid.rows - 2 do
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
			local dx, dz = px - x, pz - z
			local distance = sqrt(dx * dx + dz * dz)
			if distance > reach then
				continue
			end
			local thunder = checks.thunder(px, pz)
			local share = DistantStorms.weight(settings, thunder) / DistantStorms.weight(settings, bound)
			if keep >= share then
				continue
			end
			if ground and (distance < settings.minDistance or checks.guarded(px, pz) or not checks.rains(px, pz)) then
				ground = false
			end
			table.insert(out, {
				time = period * settings.period + offset,
				x = px,
				z = pz,
				ground = ground,
				seed = shape,
				flashes = flashes,
				thunder = thunder,
			})
		end
	end
	table.sort(out, function(a: Event, b: Event): boolean
		return a.time < b.time
	end)
	return #out, expected * scale * 60 / settings.period
end

--[[ Seen ]]

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
	The share of Config.Weather.Bolt.Flash a flash `distance` blocks away brightens the picture
	by: half at 512 blocks (as a near strike's), DayFlash of that in full daylight (`daylight`
	1: DayCycle.skyBrightness) and InCloudFlash of it for a flash inside the cloud (`ground`
	false).
]]
function DistantStorms.skyFlash(distance: number, ground: boolean, daylight: number): number
	local distant = Config.Weather.Distant
	local byDay = distant.DayFlash + (1 - distant.DayFlash) * (1 - clamp(daylight, 0, 1))
	local kind = if ground then 1 else distant.InCloudFlash
	return 1 / (1 + max(distance, 0) / 512) * kind * byDay
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
	and indoors (`exposure`: the sky exposure, Rendering/LightingController).
]]
function DistantStorms.hissVolume(level: number, near: number, exposure: number): number
	local takenOver = DistantStorms.rainLevel(near)
	return Config.Weather.Distant.Rain.Volume * clamp(level, 0, 1) * (1 - takenOver) * clamp(exposure, 0, 1)
end

return DistantStorms
