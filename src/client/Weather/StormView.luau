--!strict
--[[
	Distant storms on this client (Roblox glue over Weather/DistantStorms; the numbers in
	Config.Weather.Distant): the lightning of every thunderstorm in reach, seen and heard from far
	away (Weather/LightningView draws and plays each flash), and the hiss of rain falling nearby but
	not here.

	  Schedule  the server's clock (workspace:GetServerTimeNow) in Period-second periods. While
	            one runs, the next one's thunder is sampled around the camera at that period's
	            moment (Weather.momentAt with its start; DistantStorms.prepare and fill: a band of
	            rows a frame, CellsPerFrame cells or a thirtieth of the grid, whichever is more, so
	            it is ready long before it starts). When it starts its flashes are planned
	            (DistantStorms.plan) and handed to LightningView.distant as their times come (none
	            more than a second late). A change of the server's weather state (/weather, the
	            clock) samples the next period again.
	  Players   where no bolt may strike is read once a period: every player's feet
	            (Shared/Movement/Rig.feet) within MinDistance, and a player standing in thunder
	            (not a spectator: the server's World/WeatherServer rolls only for the others)
	            within Lightning.Radius + Margin.
	  Rain      every Rain.Interval seconds the rain level at DistantStorms.rainPoints around the
	            camera (snapped to LATTICE blocks so Weather/WeatherState's column cache serves
	            them; only where rain falls by the column's biome: snow and deserts are silent),
	            DistantStorms.hiss; its volume (hissVolume: fading as the rain here takes over,
	            indoors and underground) and direction smoothed over Rain.Smoothing seconds, and
	            played on Audio/SoundPlayer's bed of weather.rain.far, muffled by Rain.Muffle.
	  Off       no flashes with the Clouds setting Off, Distant.Enabled or Lightning.Enabled
	            false, or no weather at all (the server's own strikes still show); the hiss
	            follows Rain.Enabled and plays whatever the Clouds and Weather settings, as the
	            rain's own sound does.

	Cost (tests/spec/DistantStorms, Lune; interpreted, as Roblox clients may run it, then native):
	a period's grid around a 2048-block reach (35 x 35 cells) takes 1.7 ms (0.5 native) to sample,
	spread over its frames (128 cells, 0.18 ms, a frame); planning it 0.04 ms in a clear sky (one
	read a cell), 0.4 ms in the weather of random places and times, 1.8 ms (0.5) under /weather
	thunder, once every Period seconds; the rain's 32 points every Interval seconds. Nothing is
	allocated per frame but a flash's own tables when one comes.
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
local WeatherState = require(script.Parent.WeatherState)

-- The distant rain's points snap to this lattice (blocks).
local LATTICE = 8
-- Seconds late a flash may still be shown (a hitch, a slow frame).
local LATE = 1

local StormView = {}

local worldSeed = 0
local viewDistance: () -> number = function()
	return Config.Lod.ViewDistance
end
local settings: DistantStorms.Settings? = nil
-- What `settings` were made for.
local settingsMode, settingsView, settingsMobile = -1, -1, false
-- The running period's grid and the next one's, and their moments.
local current = DistantStorms.newGrid()
local upcoming = DistantStorms.newGrid()
local currentMoment: Weather.Moment = Weather.momentAt(WeatherState.state(), 0)
local upcomingMoment: Weather.Moment = Weather.momentAt(WeatherState.state(), 0)
local scratch: buffer? = nil
-- The period planned last, its flashes (in time order) and the next to show.
local planned = -1
local events: { DistantStorms.Event } = {}
local nextEvent = 1
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
	thunder = function(x: number, z: number): number
		local _, thunder = WeatherState.at(x, z, currentMoment)
		return thunder
	end,
	rains = function(x: number, z: number): boolean
		return WeatherState.formAt(x, nil, z) == Weather.RAIN
	end,
	guarded = function(x: number, z: number): boolean
		for i = 1, guardCount * 3, 3 do
			local dx, dz, radius = x - guards[i], z - guards[i + 1], guards[i + 2]
			if dx * dx + dz * dz <= radius * radius then
				return true
			end
		end
		return false
	end,
}

-- Reads where no bolt may strike this period (see the header).
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
			local _, thunder = WeatherState.at(feet.X, feet.Z, currentMoment)
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

local function schedule()
	local s = active()
	if s == nil then
		table.clear(events)
		nextEvent, expected, planned = 1, 0, -1
		return
	end
	local now = workspace:GetServerTimeNow()
	local period = math.floor(now / s.period)
	if planned ~= period then
		planned = period
		if upcoming.period == period and upcoming.filled >= upcoming.rows then
			current, upcoming = upcoming, current
			currentMoment, upcomingMoment = upcomingMoment, currentMoment
		end
		nextEvent = 1
		if current.period == period then
			gatherGuards(s)
			local _, perMinute =
				DistantStorms.plan(s, current, worldSeed, WeatherState.cameraX, WeatherState.cameraZ, checks, events)
			expected = perMinute
		else
			table.clear(events)
			expected = 0
		end
	end
	-- The next period's grid, a band a frame.
	if upcoming.period ~= period + 1 then
		DistantStorms.prepare(upcoming, s, period + 1, WeatherState.cameraX, WeatherState.cameraZ)
		Weather.momentAt(WeatherState.state(), (period + 1) * s.period, upcomingMoment)
	end
	if upcoming.filled < upcoming.rows then
		local budget = math.max(Config.Weather.Distant.CellsPerFrame, math.ceil(upcoming.cols * upcoming.rows / 30))
		DistantStorms.fill(upcoming, s, sample, budget)
	end
	-- The flashes whose time came.
	while nextEvent <= #events and events[nextEvent].time <= now do
		local event = events[nextEvent]
		nextEvent += 1
		if now - event.time <= LATE then
			LightningView.distant(event)
			table.insert(recent, os.clock())
		end
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
		else
			hissLevel = 0
		end
	end
	local near = if WeatherState.form == Weather.RAIN then WeatherState.intensity else 0
	local target = DistantStorms.hissVolume(hissLevel, near, LightingController.skyExposure())
	hissVolume = DayCycle.approach(hissVolume, target, dt, rain.Smoothing)
	hissDX = DayCycle.approach(hissDX, hissX, dt, rain.Smoothing)
	hissDZ = DayCycle.approach(hissDZ, hissZ, dt, rain.Smoothing)
	local muffle = rain.Muffle
	SoundPlayer.setBed(handle, hissDX, hissDZ, hissVolume, muffle.Low, muffle.Mid, muffle.High)
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
		schedule()
		hiss(dt)
	end)
end

return StormView
