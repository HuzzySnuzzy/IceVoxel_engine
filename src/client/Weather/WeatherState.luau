--!strict
--[[
	The weather as this client sees it (Roblox glue over the pure Shared/Weather): the world's
	field, the server's state, this frame's moment and the weather at the camera, for everything
	that shows the weather (Weather/PrecipitationView, CloudView, LightningView, Rendering/
	LightingController, Map/WeatherLayer, F3).

	  State     read from the workspace attributes World/WeatherServer publishes (Weather.readState),
	            again only when one of them changes; `changed` fires then (the maps' forecast
	            pictures are drawn again: an override changes the future).
	  Moment    worked out once a frame (Weather.momentAt with workspace:GetServerTimeNow(), into
	            one table): `moment`, the clock and the override's weights now; `momentIn(seconds,
	            into)` a forecast's.
	  Camera    the weather over the camera's column (Weather.at) every frame: `precipitation`,
	            `thunder`, `cover` as they are, and smoothed in time for the light (`rain`,
	            `storm`, `clouds`: Config.Weather.Sky.Smoothing, DayCycle.approach, so walking
	            out of a storm or a teleport brightens the sky over a few seconds, never in a
	            jump) and for the rain drawn (`intensity`: Precipitation.Smoothing). `form` is what
	            falls at the camera (Weather.formAt by the column's biome and the camera's height):
	            "rain", "snow" or "" (a dry biome); `kind` "clear", "rain" or "snow".
	  Columns   `temperatureAt(x, z)`: the Minecraft temperature of a column's biome (nil: nothing
	            falls there) and its natural ground height, from the generator, kept for COLUMNS
	            columns (shared by the rain, the snow line and the maps); `seaLevel()` the
	            generator's sea surface (distant bolts stand on it over water).
	  Wind      `wind()`: blocks a second now; `displacement()`: how far the air has moved (the
	            clouds' frame).

	Before the server has published anything the weather is off (always clear), as
	Weather.readState says.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Weather = require(Shared.Weather)

-- (Pure: the wind's words, as the maps write them.)
local WeatherMap = require(script.Parent.Parent.Map.WeatherMap)

local BLOCK = Config.BlockSize
-- Columns whose biome temperature and ground height are kept (the cache starts over beyond).
local COLUMNS = 16384
local COLUMN_SPAN = 67108864
local NO_TEMPERATURE = math.huge

local WeatherState = {}

local started = false
-- The camera's values are taken at once on the first frame, then smoothed.
local settled = false
local generator: TerrainGenerator.Generator? = nil
local field: Weather.Field? = nil
local state: Weather.State = Weather.newState(0, 0, true, false)
local dirty = true
local changedEvent = Instance.new("BindableEvent")
-- Fires when the server's weather state changed (an override, doWeatherCycle, the clock set).
WeatherState.changed = changedEvent.Event

-- This frame's moment (see the header).
WeatherState.moment = Weather.momentAt(state, 0)
-- The weather over the camera now, and smoothed.
WeatherState.precipitation = 0
WeatherState.thunder = 0
WeatherState.cover = 0
WeatherState.rain = 0
WeatherState.storm = 0
WeatherState.clouds = 0
WeatherState.intensity = 0
WeatherState.form = Weather.RAIN
WeatherState.kind = Weather.CLEAR
-- The camera's block cell.
WeatherState.cameraX = 0
WeatherState.cameraY = 0
WeatherState.cameraZ = 0

-- Column key -> Minecraft temperature (NO_TEMPERATURE: nothing falls) and ground height.
local temperatures: { [number]: number } = {}
local grounds: { [number]: number } = {}
local columnCount = 0

local function read(name: string): any
	return workspace:GetAttribute(name)
end

-- The world's field (nil before `start`).
function WeatherState.field(): Weather.Field?
	return field
end

-- The server's weather state (as last read).
function WeatherState.state(): Weather.State
	return state
end

-- Is there weather at all (the server's ATTRIBUTE_ENABLED)?
function WeatherState.enabled(): boolean
	return state.enabled and field ~= nil
end

-- The moment `seconds` from now (a forecast), written into `into` when given.
function WeatherState.momentIn(seconds: number, into: Weather.Moment?): Weather.Moment
	return Weather.momentAt(state, workspace:GetServerTimeNow() + seconds, into)
end

-- Precipitation, thunder and cover at (x, z) at `moment` (default this frame's); 0s without weather.
function WeatherState.at(x: number, z: number, moment: Weather.Moment?): (number, number, number)
	local world = field
	if world == nil then
		return 0, 0, 0
	end
	return world:at(x, z, moment or WeatherState.moment)
end

-- The wind now, blocks a second along x and z.
function WeatherState.wind(moment: Weather.Moment?): (number, number)
	local world = field
	if world == nil then
		return 0, 0
	end
	-- (The published rate: 0 while doWeatherCycle is off, when the air stands still.)
	local vx, vz = world:wind((moment or WeatherState.moment).time)
	return vx * state.rate, vz * state.rate
end

-- How far the air has moved by this frame's clock (blocks; the clouds' frame).
function WeatherState.displacement(): (number, number)
	local world = field
	if world == nil then
		return 0, 0
	end
	return world:displacement(WeatherState.moment.time)
end

local function column(x: number, z: number): (number?, number)
	local key = x * COLUMN_SPAN + z
	local temperature = temperatures[key]
	if temperature == nil then
		local terrain = generator
		if terrain == nil then
			return nil, Config.SeaLevel
		end
		if columnCount >= COLUMNS then
			table.clear(temperatures)
			table.clear(grounds)
			columnCount = 0
		end
		local height, biome = terrain.column(x, z)
		temperature = Weather.biomeTemperature(biome) or NO_TEMPERATURE
		temperatures[key] = temperature
		grounds[key] = height
		columnCount += 1
	end
	local value = temperature :: number
	return if value == NO_TEMPERATURE then nil else value, grounds[key]
end

--[[
	The Minecraft temperature of block column (x, z)'s biome (nil: nothing falls there) and its
	natural ground height (the generator's; kept, see the header).
]]
function WeatherState.temperatureAt(x: number, z: number): (number?, number)
	return column(math.floor(x), math.floor(z))
end

-- The sea's surface (blocks): the generator's (0 in a flat world without a sea), else Config's.
function WeatherState.seaLevel(): number
	local terrain = generator
	return if terrain and terrain.seaLevel then terrain.seaLevel else Config.SeaLevel
end

-- Is column (x, z)'s biome and ground height known already (no generator call)?
function WeatherState.knows(x: number, z: number): boolean
	return temperatures[math.floor(x) * COLUMN_SPAN + math.floor(z)] ~= nil
end

-- What falls at (x, y, z) ("rain", "snow" or ""); y nil: on the natural ground.
function WeatherState.formAt(x: number, y: number?, z: number): string
	local temperature, ground = column(math.floor(x), math.floor(z))
	return Weather.formAt(temperature, x, y or ground, z)
end

local function update(dt: number)
	if dirty then
		dirty = false
		Weather.readState(read, state)
		changedEvent:Fire()
	end
	local now = workspace:GetServerTimeNow()
	local moment = Weather.momentAt(state, now, WeatherState.moment)
	local camera = workspace.CurrentCamera
	local position = if camera then camera.CFrame.Position / BLOCK else Vector3.zero
	local x, y, z = math.floor(position.X), math.floor(position.Y), math.floor(position.Z)
	WeatherState.cameraX, WeatherState.cameraY, WeatherState.cameraZ = x, y, z
	local p, th, c = 0, 0, 0
	local world = field
	if world then
		p, th, c = world:at(position.X, position.Z, moment)
	end
	WeatherState.precipitation, WeatherState.thunder, WeatherState.cover = p, th, c
	local sky = if settled then Config.Weather.Sky.Smoothing else 0
	local falling = if settled then Config.Weather.Precipitation.Smoothing else 0
	settled = true
	WeatherState.rain = DayCycle.approach(WeatherState.rain, p, dt, sky)
	WeatherState.storm = DayCycle.approach(WeatherState.storm, th, dt, sky)
	WeatherState.clouds = DayCycle.approach(WeatherState.clouds, c, dt, sky)
	WeatherState.intensity = DayCycle.approach(WeatherState.intensity, p, dt, falling)
	local form = if generator then WeatherState.formAt(x, y, z) else Weather.RAIN
	WeatherState.form = form
	WeatherState.kind = Weather.kindOf(p, form)
end

--[[
	The weather's lines for F3: what falls at the camera ("clear", "rain", "snow"), the
	precipitation, thunder and cloud cover there (0..1), the wind (blocks a second and where it
	blows to), the weather clock (ticks) and a /weather override with its share now.
]]
function WeatherState.describe(): string
	if not WeatherState.enabled() then
		return "weather off"
	end
	local vx, vz = WeatherState.wind()
	local moment = WeatherState.moment
	local override = if moment.weight > 0
		then string.format("  /weather %s %.0f%%", moment.override, moment.weight * 100)
		else ""
	return string.format(
		"weather %s  precip %.2f  thunder %.2f  cover %.2f\n        wind %s  clock %d%s",
		WeatherState.kind,
		WeatherState.precipitation,
		WeatherState.thunder,
		WeatherState.cover,
		WeatherMap.windText(vx, vz),
		math.floor(moment.time),
		override
	)
end

--[[
	Starts following the weather: the world's field from `seed`, the server's attributes, the
	camera every frame. `terrain` (the world's generator) gives biomes and ground heights.
]]
function WeatherState.start(seed: number, terrain: TerrainGenerator.Generator?)
	assert(not started, "WeatherState.start was already called")
	started = true
	generator = terrain
	field = Weather.setSeed(seed)
	for _, name in
		{
			Weather.ATTRIBUTE_ENABLED,
			Weather.ATTRIBUTE_TIME,
			Weather.ATTRIBUTE_SYNC,
			Weather.ATTRIBUTE_RATE,
			Weather.ATTRIBUTE_OVERRIDE,
		}
	do
		workspace:GetAttributeChangedSignal(name):Connect(function()
			dirty = true
		end)
	end
	update(0)
	-- (Before the other weather modules' Heartbeat work: they read this frame's values.)
	RunService:BindToRenderStep("IceVoxelWeatherState", Enum.RenderPriority.Camera.Value + 2, update)
end

return WeatherState
