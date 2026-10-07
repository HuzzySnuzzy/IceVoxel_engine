--!strict
--[[
	The weather on the server: the world's weather clock and /weather overrides (Shared/Weather),
	published for the clients, and what the weather does to the world (rain on fire, on players and
	on the undead; lightning).

	  Clock      a Weather.State: published as workspace attributes (Weather.writeState: the clock
	             as a value, its server time and its rate, like World/TimeOfDay's, and the
	             override as one string) when it changes, and again every RESYNC_SECONDS (which
	             only restores them if another script changed them). Clients compute the same
	             closed form, so nothing is sent while it runs. A new world's clock starts at
	             Weather.clearStart for the spawn column (Config.Weather.ClearStartSeconds of dry
	             weather there first, as Minecraft's first rain waits); a saved world's where it
	             was (`decode`, before or after `start`).
	  Override   /weather (Players/WeatherCommands: `setOverride`), dropped once it has run out
	             (checked every second; it blended out by then); /gamerule doWeatherCycle
	             (Players/TimeCommands: `setCycle`) stops the clock and holds an override's time.
	  Off        with Config.Weather.Enabled false, or in a world type without ticks (the debug
	             worlds: `start`'s `enabled`), the published state says so and it never rains.
	  Rain       `rainingAt(x, y, z)`: World/WeatherRules.rainingAt (Minecraft's Level.isRainingAt)
	             with the weather now (the moment worked out once a frame) and the column's biome
	             (the generator's, Weather.biomeTemperature, cached per column). Behaviours/Fire
	             gets it (Fire.setRain: rain puts fire out and stops it spreading), Players/
	             ToughAsNails (rain makes players wet) and Mobs/Mobs (no burning in the rain) ask it.
	  Day        `isDayAt(x, z, dayTime)`: Weather.isDay with the weather over the column (no
	             daylight burning in a thunderstorm).
	  Lightning  once a second, every player in a thunderstorm (not a spectator) may draw a strike
	             near them (World/Lightning: the rate, the target, the fires); the handler the boot
	             script sets (`setHandler`) hurts the living it reaches (Players/Characters,
	             Mobs/Mobs), and every player within Config.Weather.Lightning.Distance gets a
	             Lightning message for the bolt, the flash and the thunder.
	  Saving     `encode()` and `decode(text)` (Weather.encodeState: the clock, doWeatherCycle and
	             the override with its time left) for the world's save.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Weather = require(Shared.Weather)

local WorldServer = require(script.Parent.WorldServer)
local WeatherRules = require(script.Parent.WeatherRules)
local Lightning = require(script.Parent.Lightning)
local Skylight = require(script.Parent.Skylight)
local Fire = require(script.Parent.Parent.Behaviours.Fire)

-- Only what this uses of ServerNet.ServerNet.
type Net = { send: (player: Player, kind: number, payload: buffer) -> () }

-- Seconds between writing the (unchanged) attributes again.
local RESYNC_SECONDS = 60
-- Seconds between lightning rolls and override checks.
local STEP_SECONDS = 1
-- Columns whose biome temperature is kept (cleared when full).
local MAX_COLUMNS = 8192
-- The body a player is: the standing box.
local BODY = PlayerPhysics.dimensions("standing")

local WeatherServer = {}

local state: Weather.State = Weather.newState()
local field: Weather.Field? = nil
local world: WorldServer.World? = nil
local net: Net? = nil
local started = false
-- A saved state given before `start`.
local pending: string? = nil
-- The moment of this frame (see the header).
local moment: Weather.Moment? = nil
local momentFrame = -1
local frame = 0
-- Minecraft temperature per column (DRY: nothing falls there).
local temperatures: { [number]: number } = {}
local DRY = math.huge
local columnCount = 0
local random = Random.new()

-- What the boot script connects (see `setHandler`).
local strikeHandler: ((x: number, y: number, z: number) -> ())? = nil
local livingHandler: ((x: number, y: number, z: number, radius: number) -> { Lightning.Living })? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function publish()
	if started then
		Weather.writeState(state, function(name: string, value: any)
			workspace:SetAttribute(name, value)
		end)
	end
	moment = nil
end

-- The weather's moment this frame.
local function current(): Weather.Moment
	local value = moment
	if value ~= nil and momentFrame == frame then
		return value
	end
	local fresh = Weather.momentAt(state, now())
	moment = fresh
	momentFrame = frame
	return fresh
end

-- Minecraft temperature of column (x, z)'s biome (nil: nothing falls), from the generator.
local function temperatureOf(x: number, z: number): number?
	local key = x * 67108864 + z
	local known = temperatures[key]
	if known == nil then
		local serverWorld = world :: WorldServer.World
		local _, biome = serverWorld.generator.column(x, z)
		known = Weather.biomeTemperature(biome) or DRY
		if columnCount >= MAX_COLUMNS then
			table.clear(temperatures)
			columnCount = 0
		end
		temperatures[key] = known
		columnCount += 1
	end
	return if known == DRY then nil else known
end

--[[ Queries ]]

-- Does this world have weather?
function WeatherServer.enabled(): boolean
	return state.enabled
end

-- Is the weather clock running (doWeatherCycle)?
function WeatherServer.cycle(): boolean
	return state.cycle
end

-- The weather clock now (ticks).
function WeatherServer.clock(): number
	return Weather.clock(state, now())
end

-- The weather's state (read only: change it with the functions below).
function WeatherServer.state(): Weather.State
	return state
end

-- Precipitation, thunder and cloud cover (0..1) over column (x, z) now.
function WeatherServer.sample(x: number, z: number): (number, number, number)
	local fieldNow = field
	if fieldNow == nil or not state.enabled then
		return 0, 0, 0
	end
	return fieldNow:at(x, z, current())
end

-- Is it raining on cell (x, y, z) now (Minecraft's Level.isRainingAt; see the header)?
function WeatherServer.rainingAt(x: number, y: number, z: number): boolean
	if not started or world == nil then
		return false
	end
	x, y, z = math.floor(x), math.floor(y), math.floor(z)
	local precipitation = WeatherServer.sample(x, z)
	if precipitation <= Weather.RAINING then
		return false
	end
	return WeatherRules.rainingAt(world, x, y, z, precipitation, temperatureOf(x, z))
end

-- Is it day at column (x, z) at `dayTime`, the weather's darkening counted (Level.isDay)?
function WeatherServer.isDayAt(x: number, z: number, dayTime: number): boolean
	local precipitation, thunder = WeatherServer.sample(math.floor(x), math.floor(z))
	return Weather.isDay(dayTime, precipitation, thunder)
end

-- The weather at cell (x, y, z) for /weather query: "clear", "rain", "snow" or "thunder".
function WeatherServer.describe(x: number, y: number, z: number): string
	if not started or not state.enabled then
		return Weather.CLEAR
	end
	x, y, z = math.floor(x), math.floor(y), math.floor(z)
	local precipitation, thunder = WeatherServer.sample(x, z)
	local kind = Weather.kindOf(precipitation, Weather.formAt(temperatureOf(x, z), x, y, z))
	if kind == Weather.RAIN and thunder > 0.5 then
		return Weather.THUNDER
	end
	return kind
end

--[[ Changes ]]

-- Starts or stops the weather clock (doWeatherCycle).
function WeatherServer.setCycle(on: boolean)
	Weather.setCycle(state, on, now())
	publish()
end

-- Sets override `kind` (Weather.CLEAR, RAIN or THUNDER) for `seconds` (/weather).
function WeatherServer.setOverride(kind: string, seconds: number)
	Weather.setOverride(state, kind, seconds, now())
	publish()
end

-- Sets the weather clock (ticks).
function WeatherServer.setClock(time: number)
	Weather.setClock(state, time, now())
	publish()
end

--[[
	The handler of strikes (the boot script's, as World/Explosions'): `strike(x, y, z)` hurts the
	living a bolt at (x, y, z) reaches (blocks: the bottom centre of the struck cell); `living`
	(optional) lists the living things other than players near (x, y, z) (mobs: World/Lightning's
	target search; players are this module's own).
]]
function WeatherServer.setHandler(
	strike: ((x: number, y: number, z: number) -> ())?,
	living: ((x: number, y: number, z: number, radius: number) -> { Lightning.Living })?
)
	strikeHandler = strike
	livingHandler = living
end

--[[ Saving ]]

-- The state for the world's save (Weather.encodeState).
function WeatherServer.encode(): string
	return Weather.encodeState(state, now())
end

--[[
	Restores a saved state (WeatherServer.encode's text): at once when the weather has started,
	else when it starts. Returns false (and changes nothing) when the text is malformed.
]]
function WeatherServer.decode(text: string): boolean
	local restored = Weather.decodeState(text, now(), state.enabled)
	if restored == nil then
		return false
	end
	if not started then
		pending = text
		return true
	end
	state = restored
	publish()
	return true
end

--[[ Lightning ]]

local function feetOf(player: Player): Vector3?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if character == nil or humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	local feet = Rig.feet(character)
	if
		feet == nil
		or not (math.abs(feet.X) <= Protocol.MAX_COORDINATE)
		or not (math.abs(feet.Y) <= Protocol.MAX_COORDINATE)
		or not (math.abs(feet.Z) <= Protocol.MAX_COORDINATE)
	then
		return nil
	end
	return feet
end

local function roll(): number
	return random:NextNumber()
end

local view: Lightning.View = {
	top = function(x: number, z: number): (number, boolean)
		local serverWorld = world :: WorldServer.World
		local top = WeatherRules.top(serverWorld, x, z)
		if top then
			return top, true
		end
		local height = serverWorld.generator.column(x, z)
		return height, false
	end,
	living = function(x: number, y: number, z: number, radius: number): { Lightning.Living }
		local list: { Lightning.Living } = {}
		local limit = radius * radius
		for _, player in Players:GetPlayers() do
			local feet = feetOf(player)
			if feet and not GameMode.isSpectator(GameMode.of(player)) then
				local dx, dy, dz = feet.X - x, feet.Y - y, feet.Z - z
				if dx * dx + dy * dy + dz * dz <= limit then
					table.insert(list, {
						x = feet.X,
						y = feet.Y,
						z = feet.Z,
						width = BODY.width,
						height = BODY.height,
						key = player,
					})
				end
			end
		end
		local others = livingHandler
		if others then
			for _, living in others(x, y, z, radius) do
				table.insert(list, living)
			end
		end
		return list
	end,
	skyOpen = function(x: number, y: number, z: number): boolean
		return Skylight.clear(world, x, y, z) == true
	end,
	raining = function(x: number, y: number, z: number): boolean
		local serverWorld = world :: WorldServer.World
		local precipitation = WeatherServer.sample(x, z)
		if precipitation <= Weather.RAINING then
			return false
		end
		local top = WeatherRules.top(serverWorld, x, z)
		if top == nil then
			-- (Not loaded: the generator's ground, open to the sky.)
			return Weather.formAt(temperatureOf(x, z), x, y, z) == Weather.RAIN
		end
		return WeatherRules.rainingAt(serverWorld, x, y, z, precipitation, temperatureOf(x, z))
	end,
}

-- A bolt at cell (x, y, z): fires, the living, and the clients near (see the header).
local function strike(x: number, y: number, z: number, loaded: boolean)
	local serverWorld = world :: WorldServer.World
	if loaded and Config.Server.Fire.Tick then
		local getBlock = function(bx: number, by: number, bz: number): number?
			return serverWorld:peekBlock(bx, by, bz)
		end
		for _, cell in Lightning.fireCells(getBlock, x, y, z, Config.Server.Fire.Difficulty, roll) do
			Fire.ignite(serverWorld, cell[1], cell[2], cell[3], 0)
		end
	end
	local bx, by, bz = x + 0.5, y, z + 0.5
	local handler = strikeHandler
	if loaded and handler then
		handler(bx, by, bz)
	end
	local sender = net
	if sender == nil then
		return
	end
	local flashes, seed = Lightning.bolt(roll)
	local payload = Protocol.encodeLightning({ x = bx, y = by, z = bz, seed = seed, flashes = flashes })
	local reach = Config.Weather.Lightning.Distance
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local feet = if character then Rig.feet(character) else nil
		if feet and (feet - Vector3.new(bx, by, bz)).Magnitude <= reach then
			sender.send(player, Protocol.ServerMessage.Lightning, payload)
		end
	end
end

-- One second's lightning near every player in a thunderstorm.
local function lightningStep()
	local settings = Config.Weather.Lightning
	if not settings.Enabled or not state.enabled then
		return
	end
	for _, player in Players:GetPlayers() do
		local feet = feetOf(player)
		if feet == nil or GameMode.isSpectator(GameMode.of(player)) then
			continue
		end
		local _, thunder = WeatherServer.sample(math.floor(feet.X), math.floor(feet.Z))
		if roll() >= Lightning.chance(thunder, settings.MeanSeconds, STEP_SECONDS) then
			continue
		end
		local dx, dz = Lightning.pick(roll, settings.Radius)
		local x, y, z, loaded = Lightning.target(view, math.floor(feet.X + dx), math.floor(feet.Z + dz), roll)
		if x and y and z then
			strike(x, y, z, loaded)
		end
	end
end

--[[
	Starts the weather for the world `serverWorld` of `seed` (`enabled` false: none, the debug
	worlds), with `serverNet` for the bolts. Behaviours/Fire gets the rain from here on.
]]
function WeatherServer.start(serverNet: Net, serverWorld: WorldServer.World, seed: number, enabled: boolean)
	assert(not started, "WeatherServer.start was already called")
	net = serverNet
	world = serverWorld
	local on = enabled and Config.Weather.Enabled
	field = Weather.setSeed(seed)
	local restored = if pending then Weather.decodeState(pending, now(), on) else nil
	pending = nil
	if restored then
		state = restored
	else
		local clock = 0
		if on and Config.Weather.ClearStartSeconds > 0 then
			local sx, _, sz = serverWorld.generator.findSpawn()
			clock = Weather.clearStart(field :: Weather.Field, sx, sz, Config.Weather.ClearStartSeconds)
		end
		state = Weather.newState(clock, now(), state.cycle, on)
	end
	started = true
	publish()
	if on then
		Fire.setRain(function(_world: any, x: number, y: number, z: number): boolean
			return WeatherServer.rainingAt(x, y, z)
		end)
	end

	local stepClock, resyncClock = 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		frame += 1
		stepClock += dt
		resyncClock += dt
		if stepClock >= STEP_SECONDS then
			stepClock = 0
			if Weather.expire(state, now()) then
				publish()
			end
			lightningStep()
		end
		if resyncClock >= RESYNC_SECONDS then
			resyncClock = 0
			publish()
		end
	end)
end

return WeatherServer
