--!strict
--[[
	Distant storms on this client (Roblox glue over Weather/DistantStorms; the numbers in
	Config.Weather.Distant): the lightning of every thunderstorm in reach, seen and heard from far
	away (Weather/LightningView draws and plays each flash), and the hiss of rain falling nearby but
	not here.

	  Schedule  the server's clock (workspace:GetServerTimeNow) in Period-second periods. While
	            one runs, the next one's flashes are worked out around the camera, a band of rows a
	            frame (DistantStorms.prepare and advance: its thunder sampled at that period's moment,
	            Weather.momentAt with its start, then each cell rolled), as many rows a frame as
	            DistantStorms.budget gives for it to be ready before it starts at the frame rate now
	            (smoothed over about ten frames): no frame does it all, and none is thrown away. When
	            it starts its flashes are handed to LightningView.distant as their times come (none
	            more than LATE late: one that came in late, after a change, shows the rest). A
	            change of the server's weather state (/weather, the clock) works the next period
	            out again.
	  Players   as a bolt shows, where it may not strike (DistantStorms.strikes): within
	            MinDistance of the camera or of any player's feet (Shared/Movement/Rig.feet), or
	            within Lightning.Radius + Margin of a player standing in thunder (not a spectator:
	            the server's World/WeatherServer rolls only for the others): it flashes in the cloud.
	  Rain      every Rain.Interval seconds the rain level at DistantStorms.rainPoints around the
	            camera (snapped to LATTICE blocks so Weather/WeatherState's column cache serves
	            them; only where rain falls by the column's biome: snow and deserts are silent),
	            DistantStorms.hiss, and whether a block that stops rain is over the camera
	            (Weather/PrecipitationView.roofed, its column's rain floor); its volume (hissVolume:
	            fading as the rain here takes over, underground, and to Rain.Roofed under a roof),
	            direction and roof smoothed over Rain.Smoothing seconds, and played on
	            Audio/SoundPlayer's bed of weather.rain.far, muffled by Rain.Muffle (hissMuffle:
	            Rain.RoofMuffle under a roof).
	  Off       no flashes with the Clouds setting Off, Distant.Enabled or Lightning.Enabled
	            false, or no weather at all (the server's own strikes still show); the hiss
	            follows Rain.Enabled and plays whatever the Clouds and Weather settings, as the
	            rain's own sound does.

	Cost (tests/spec/DistantStorms, Lune; interpreted, as Roblox clients may run it, then native): a
	period's grid around a 2048-block reach (35 x 35 cells) takes 1.5 ms (0.5 native) to sample and
	0.9 ms (0.4) to roll under /weather thunder (0.1 in the weather of random places and times, none
	in a clear sky); around Ultra's 4096 (67 x 67) 5.1 and 3.5 ms (1.9, 1.5). All of it is spread
	over the frames of the period before: at 60 fps 3 rows a frame at 2048 and 2 at 4096 (99 in 100
	frames under 0.2-0.5 ms interpreted), at 15 fps 4 and 6. The rain's 32 points every Interval
	seconds. Nothing is allocated per frame but a flash's own tables when one comes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local GameMode = require(Shared.GameMode)
local Rig = require(Shared.Movement.Rig)
local Weather = require(Shared.Weather)

local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local ViewSettings = require(script.Parent.Parent.Rendering.ViewSettings)
local CloudLod = require(script.Parent.CloudLod)
local CloudView = require(script.Parent.CloudView)
local DistantStorms = require(script.Parent.DistantStorms)
local LightningView = require(script.Parent.LightningView)
local PrecipitationView = require(script.Parent.PrecipitationView)
local WeatherState = require(script.Parent.WeatherState)

-- The distant rain's points snap to this lattice (blocks).
local LATTICE = 8
-- Seconds late a flash may still be shown (a hitch, a slow frame, a period worked out late).
local LATE = 1
-- The frame time the work is shared out by follows each frame's by this share (about ten frames'
-- average), a hitch counting as HITCH seconds at most.
local FRAME_SMOOTHING = 0.1
local HITCH = 0.25

local StormView = {}

local worldSeed = 0
local viewDistance: () -> number = function()
	return Config.Lod.ViewDistance
end
local settings: DistantStorms.Settings? = nil
-- What `settings` were made for.
local settingsMode, settingsView, settingsMobile = -1, -1, false
-- The running period's flashes and the next one's being worked out (at its moment).
local current = DistantStorms.newGrid()
local upcoming = DistantStorms.newGrid()
local upcomingMoment: Weather.Moment = Weather.momentAt(WeatherState.state(), 0)
local scratch: buffer? = nil
-- The next of the running period's flashes to show, and the frame time (smoothed).
local nextEvent = 1
local frameTime = 1 / 60
-- The flashes a minute the plan expected, and when (os.clock) the last minute's were shown.
local expected = 0
local recent: { number } = {}
-- Where no bolt strikes: x, z and a radius (blocks), three numbers a point.
local guards: { number } = {}
local guardCount = 0
-- The rain's points, its bed, the last sample (level, direction) and what plays.
local points = DistantStorms.rainPoints()
local bed: number? = nil
local hissClock = math.huge
local hissLevel, hissX, hissZ = 0, 0, 0
local hissVolume, hissDX, hissDZ = 0, 0, 0
-- Whether a roof is over the camera (sampled), and smoothed (0 in the open, 1 under it).
local roofed, roof = false, 0
local originX, originZ = 0, 0

-- The weather field's grid at the upcoming period's moment (DistantStorms.Sampler).
local function sample(x0: number, z0: number, step: number, cols: number, rows: number): buffer
	local field = WeatherState.field()
	if field == nil then
		return buffer.create(cols * rows * 3)
	end
	local out = field:grid(upcomingMoment, x0, z0, step, cols, rows, scratch)
	scratch = out
	return out
end

local checks: DistantStorms.Checks = {
	-- (The flashes being rolled are the upcoming period's.)
	thunder = function(x: number, z: number): number
		local _, thunder = WeatherState.at(x, z, upcomingMoment)
		return thunder
	end,
	rains = function(x: number, z: number): boolean
		return WeatherState.formAt(x, nil, z) == Weather.RAIN
	end,
}

-- Is a player near (x, z) (blocks), as `gatherGuards` read them?
local function guarded(x: number, z: number): boolean
	for i = 1, guardCount * 3, 3 do
		local dx, dz, radius = x - guards[i], z - guards[i + 1], guards[i + 2]
		if dx * dx + dz * dz <= radius * radius then
			return true
		end
	end
	return false
end

-- Reads where no bolt may strike now (see the header).
local function gatherGuards(s: DistantStorms.Settings)
	guardCount = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local feet = if character then Rig.feet(character) else nil
		if feet == nil then
			continue
		end
		local radius = s.minDistance
		if not GameMode.isSpectator(GameMode.of(player)) then
			local _, thunder = WeatherState.at(feet.X, feet.Z)
			if thunder > 0 then
				radius = math.max(radius, s.guard)
			end
		end
		local at = guardCount * 3
		guards[at + 1], guards[at + 2], guards[at + 3] = feet.X, feet.Z, radius
		guardCount += 1
	end
end

-- The settings when distant flashes are made now, else nil (see the header's Off).
local function active(): DistantStorms.Settings?
	local distant = Config.Weather.Distant
	if not distant.Enabled or not Config.Weather.Lightning.Enabled or not WeatherState.enabled() then
		return nil
	end
	local mode = CloudView.mode()
	if mode == CloudLod.OFF then
		return nil
	end
	local view, mobile = viewDistance(), ViewSettings.isMobile()
	if settings == nil or mode ~= settingsMode or view ~= settingsView or mobile ~= settingsMobile then
		settingsMode, settingsView, settingsMobile = mode, view, mobile
		settings = DistantStorms.settings(mode, view, mobile)
		-- (Another reach: both grids are sampled again.)
		current.period, upcoming.period = -1, -1
	end
	return settings
end

local function schedule(dt: number)
	local s = active()
	if s == nil then
		current.period, upcoming.period = -1, -1
		nextEvent, expected = 1, 0
		return
	end
	frameTime += (math.min(dt, HITCH) - frameTime) * FRAME_SMOOTHING
	local now = workspace:GetServerTimeNow()
	local period = math.floor(now / s.period)
	-- The next period's flashes, a band of rows a frame (one still being worked out for this
	-- period, late, is finished first; one for a period gone by is dropped).
	if upcoming.period < period or upcoming.period > period + 1 then
		DistantStorms.prepare(upcoming, s, period + 1, WeatherState.cameraX, WeatherState.cameraZ)
		Weather.momentAt(WeatherState.state(), (period + 1) * s.period, upcomingMoment)
	end
	if not upcoming.ready then
		local budget = DistantStorms.budget(upcoming, s, frameTime, now)
		DistantStorms.advance(upcoming, s, sample, worldSeed, checks, budget)
	end
	-- Its period came (or it is ready late in it): its flashes are shown now.
	if upcoming.ready and upcoming.period == period then
		current, upcoming = upcoming, current
		nextEvent = 1
		expected = DistantStorms.perMinute(s, current)
	end
	if current.period == period then
		-- The flashes whose time came.
		local events = current.events
		while nextEvent <= #events and events[nextEvent].time <= now do
			local event = events[nextEvent]
			nextEvent += 1
			if now - event.time <= LATE then
				if event.ground then
					gatherGuards(s)
					event.ground = DistantStorms.strikes(s, event, WeatherState.cameraX, WeatherState.cameraZ, guarded)
				end
				LightningView.distant(event)
				table.insert(recent, os.clock())
			end
		end
	else
		expected = 0
	end
	local clock = os.clock()
	while #recent > 0 and clock - recent[1] > 60 do
		table.remove(recent, 1)
	end
end

-- The rain level (DistantStorms.rainLevel) `dx`, `dz` blocks from the sampled camera.
local function rainLevelAt(dx: number, dz: number): number
	local x = math.floor((originX + dx) / LATTICE) * LATTICE + LATTICE / 2
	local z = math.floor((originZ + dz) / LATTICE) * LATTICE + LATTICE / 2
	local precipitation = WeatherState.at(x, z)
	if precipitation <= Weather.RAINING or WeatherState.formAt(x, nil, z) ~= Weather.RAIN then
		return 0
	end
	return DistantStorms.rainLevel(precipitation)
end

local function hiss(dt: number)
	local handle = bed
	if handle == nil then
		return
	end
	local rain = Config.Weather.Distant.Rain
	hissClock += dt
	if hissClock >= rain.Interval then
		hissClock = 0
		if rain.Enabled and WeatherState.enabled() and SoundPlayer.isEnabled() then
			originX, originZ = WeatherState.cameraX, WeatherState.cameraZ
			hissLevel, hissX, hissZ = DistantStorms.hiss(points, rainLevelAt)
			roofed = hissLevel > 0 and PrecipitationView.roofed()
		else
			hissLevel = 0
		end
	end
	roof = DayCycle.approach(roof, if roofed then 1 else 0, dt, rain.Smoothing)
	local near = if WeatherState.form == Weather.RAIN then WeatherState.intensity else 0
	local target = DistantStorms.hissVolume(hissLevel, near, LightingController.skyExposure(), roof)
	hissVolume = DayCycle.approach(hissVolume, target, dt, rain.Smoothing)
	hissDX = DayCycle.approach(hissDX, hissX, dt, rain.Smoothing)
	hissDZ = DayCycle.approach(hissDZ, hissZ, dt, rain.Smoothing)
	local low, mid, high = DistantStorms.hissMuffle(roof)
	SoundPlayer.setBed(handle, hissDX, hissDZ, hissVolume, low, mid, high)
end

--[[
	F3: the flashes a minute expected in reach (after the cap), how many were shown in the last
	minute, and the distant rain's cue volume now.
]]
function StormView.stats(): (number, number, number)
	return expected, #recent, hissVolume
end

-- Starts the distant storms of world `seed`, `distance()` the view distance (blocks).
function StormView.start(seed: number, distance: () -> number)
	worldSeed = seed
	viewDistance = distance
	bed = SoundPlayer.newBed("weather.rain.far")
	WeatherState.changed:Connect(function()
		-- (The forecast changed: the next period is sampled again.)
		upcoming.period = -1
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		schedule(dt)
		hiss(dt)
	end)
end

return StormView
