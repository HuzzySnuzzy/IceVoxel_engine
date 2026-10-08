--!strict
--[[
	Drives the Lighting service from the day time (the "fullbright" fix). Roblox's engine does the
	actual lighting: Future technology with shadows (default.project.json), the sun and moon placed
	by Lighting.ClockTime, sky occlusion for indoor and cave darkness. This module only picks the
	values, Config.Lighting blended by Shared/DayCycle.environment:

	  Clock      the server's clock (workspace attributes, see server World/TimeOfDay) read with
	             workspace:GetServerTimeNow(), so every client shows the same time with no traffic.
	             ClockTime puts the sun at Minecraft's celestial angle (DayCycle.clockTime).
	  Daylight   Night to Day by Minecraft's sky brightness, warm Dusk colours mixed in around
	             sunrise and sunset. Both follow the height of the sun Roblox draws
	             (Lighting:GetSunDirection), which GeographicLatitude and the Earth's tilt move away
	             from Minecraft's path, so the light always matches the sky.
	  Darkness   Lighting.Ambient (CaveAmbient) is the only light the engine gives places closed
	             to the sky, so caves and rooms are dark at any time of day. Its sky occlusion only
	             reaches so far, though, so the sky's light (outdoor ambient, sun, sky box) also
	             fades out with the camera's depth under the natural ground (Underground; the
	             generator's height of the camera's column), unless the client's block data shows
	             the sky nearby: nothing opaque above the camera (a pit or shaft), or open air a
	             few blocks away (a tunnel into a hillside, a quarry under an overhang; the fade
	             then follows the distance to it). See Rendering/SkyExposure.
	  Haze       a Lighting Atmosphere (Rendering/AtmosphereModel.state, written every update,
	             only what changed): its Density from the view distance and the weather's fog
	             factor (ViewSettings), thinned out deep underground by the exposure; its Color,
	             Haze, Glare and Decay from the time of day (DayCycle.environment, the colour's
	             floor: AtmosphereModel.floor) and then the weather (Weather/WeatherSky.apply);
	             none with the Fog setting off (ViewSettings.usesFog).
	             `start` drives the place's first Atmosphere (default.project.json's) or makes
	             "IceVoxelAtmosphere", and makes "IceVoxelSky" when Lighting has no Sky (Roblox
	             ignores an Atmosphere without one); a second Atmosphere is taken out of Lighting
	             (which one Roblox would use is undefined).
	  Fog        the old Lighting fog only shows inside a fluid and under Blindness (ViewSettings
	             takes the Atmosphere out meanwhile): FogColor is the fluid's colour
	             (`setFogColour`, Rendering/FluidFog) or a status effect's over it (Blindness:
	             black, `setEffectFogColour`, Rendering/EffectView), else the place's own.
	  Weather    the weather over the camera (Weather/WeatherState, smoothed over a second or two)
	             darkens what the sky gives by Minecraft's rain and thunder darkening, hides some
	             of the sun under full cloud cover and darkens the fog's colour (Weather/
	             WeatherSky.apply), as much as the sky reaches the camera: caves don't change.
	  Effects    Night Vision (`setNightVision`, Rendering/EffectView: its scale, 0..1, flickering
	             in its last 10 s) raises the ambient and outdoor ambient towards
	             Config.Effects.NightVisionAmbient's grey, so caves and nights read lit, as
	             Minecraft's lightmap does; a change of scale writes at once.

	Roblox lights the sky and the Atmosphere's haze by the sun and moon itself. Config.Lighting
	.Enabled = false leaves everything but ClockTime to the place, its own Atmosphere and Sky too
	(the exposure is still worked out: the cave ambience and F3 read it; the short fogs still take
	an Atmosphere out of Lighting while they show; default.project.json's Atmosphere is IceVoxel's
	and goes, so the old view fog follows the view: ViewSettings.atmosphere). Values are written
	every Config.Lighting.UpdateInterval seconds, and only when they changed (outside sunrise,
	sunset and the underground fade only ClockTime does).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local Origin = require(Shared.World.Origin)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local AtmosphereModel = require(script.Parent.AtmosphereModel)
local SkyExposure = require(script.Parent.SkyExposure)
local ViewSettings = require(script.Parent.ViewSettings)
local WeatherSky = require(script.Parent.Parent.Weather.WeatherSky)
local WeatherState = require(script.Parent.Parent.Weather.WeatherState)

local BLOCK = Config.BlockSize
-- Natural ground heights kept (columns); the cache starts over beyond that.
local GROUND_CACHE = 4096
-- Column keys: x * COLUMN_SPAN + z (|z| < 2^20).
local COLUMN_SPAN = 2097152

local LightingController = {}

local started = false
local generator: TerrainGenerator.Generator? = nil
-- The client's blocks, as SkyExposure reads them (nil: without a world).
local getBlock: SkyExposure.GetBlock? = nil
-- Sky light reaching the camera, smoothed (1 outdoors, 0 deep underground); nil before the first
-- update, which takes the target at once.
local exposure: number? = nil
-- Natural ground heights (first air block) by column key: the camera's column and those the
-- sideways probe passes (up to a few hundred an update, at some 15 microseconds a column).
local grounds: { [number]: number } = {}
local groundCount = 0
-- Lighting property -> the value written last.
local written: { [string]: any } = {}
-- The fog colour of the fluid the camera is in (nil: none) and the place's own fog colour
-- (captured before a fluid first changes it).
local fogOverride: Color3? = nil
-- A status effect's fog colour (Blindness), over the fluid's.
local effectFog: Color3? = nil
-- Night Vision's scale (0: none .. 1) and whether it changed since the last update.
local nightVision = 0
local nightVisionChanged = false
local placeFogColour: Color3? = nil
local lighting: any = Lighting
-- Something the haze follows changed (`refresh`): update at the next frame.
local refreshed = false
-- The Atmosphere worked out at the last update, and what was written to which Atmosphere (density
-- in thousandths, haze, glare and offset in hundredths, colours in whole steps: Roblox redraws its
-- sky for each change and steps through quick ones).
local atmosphereState = AtmosphereModel.new()
local shown = {
	atmosphere = nil :: Atmosphere?,
	density = -1,
	offset = -1,
	haze = -1,
	glare = -1,
	r = -1,
	g = -1,
	b = -1,
	dr = -1,
	dg = -1,
	db = -1,
}

local function attribute(name: string, fallback: number): number
	local value = workspace:GetAttribute(name)
	return if type(value) == "number" then value else fallback
end

local function write(property: string, value: any)
	if written[property] ~= value then
		written[property] = value
		lighting[property] = value
	end
end

local function colour(rgb: { number }): Color3
	return Color3.new(rgb[1] / 255, rgb[2] / 255, rgb[3] / 255)
end

-- Writes `state` (AtmosphereModel.State) into `atmosphere`: only what changed since it was last
-- written (everything into an Atmosphere not written before).
local function writeAtmosphere(atmosphere: Atmosphere, state: AtmosphereModel.State)
	if shown.atmosphere ~= atmosphere then
		shown.atmosphere = atmosphere
		shown.density, shown.offset, shown.haze, shown.glare = -1, -1, -1, -1
		shown.r, shown.g, shown.b, shown.dr, shown.dg, shown.db = -1, -1, -1, -1, -1, -1
	end
	local density = math.floor(state.density * 1000 + 0.5)
	if density ~= shown.density then
		shown.density = density
		atmosphere.Density = density / 1000
	end
	local offset = math.floor(state.offset * 100 + 0.5)
	if offset ~= shown.offset then
		shown.offset = offset
		atmosphere.Offset = offset / 100
	end
	local haze = math.floor(state.haze * 100 + 0.5)
	if haze ~= shown.haze then
		shown.haze = haze
		atmosphere.Haze = haze / 100
	end
	local glare = math.floor(state.glare * 100 + 0.5)
	if glare ~= shown.glare then
		shown.glare = glare
		atmosphere.Glare = glare / 100
	end
	local c, d = state.color, state.decay
	local r, g, b = math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5)
	if r ~= shown.r or g ~= shown.g or b ~= shown.b then
		shown.r, shown.g, shown.b = r, g, b
		atmosphere.Color = Color3.fromRGB(r, g, b)
	end
	r, g, b = math.floor(d[1] + 0.5), math.floor(d[2] + 0.5), math.floor(d[3] + 0.5)
	if r ~= shown.dr or g ~= shown.dg or b ~= shown.db then
		shown.dr, shown.dg, shown.db = r, g, b
		atmosphere.Decay = Color3.fromRGB(r, g, b)
	end
end

-- The natural ground height of block column (x, z) (integers). Needs the generator.
local function groundAt(x: number, z: number): number
	local key = x * COLUMN_SPAN + z
	local height = grounds[key]
	if height == nil then
		local terrain = generator
		assert(terrain, "groundAt needs the world's generator")
		if groundCount >= GROUND_CACHE then
			table.clear(grounds)
			groundCount = 0
		end
		height = (terrain.column(x, z))
		grounds[key] = height
		groundCount += 1
	end
	return height :: number
end

-- How much sky light should reach the camera now (SkyExposure.target; the camera in world blocks:
-- Shared/World/Origin).
local function targetExposure(): number
	local camera = workspace.CurrentCamera
	if camera == nil or generator == nil then
		return 1
	end
	local x, y, z = Origin.renderToBlocks(camera.CFrame.Position)
	return SkyExposure.target(x, y, z, groundAt, getBlock, Config.Lighting.Underground)
end

local function update(dt: number)
	local dayTime = LightingController.dayTime()
	write("ClockTime", DayCycle.clockTime(dayTime))
	local settings = Config.Lighting
	-- Worked out even when the place keeps its own lighting: the cave ambience and F3 read it.
	local current = DayCycle.approach(exposure, targetExposure(), dt, settings.Underground.Seconds)
	exposure = current
	if not settings.Enabled then
		return
	end

	-- Blend by the sun as Roblox draws it (after the ClockTime above): GeographicLatitude and the
	-- Earth's tilt move it away from Minecraft's path, and the light should match the sky.
	local sunHeight = Lighting:GetSunDirection().Y
	local environment = DayCycle.environment(dayTime, current, settings, sunHeight)
	-- (The haze colour's floor goes on the time of day's colour, before the weather darkens it.)
	AtmosphereModel.floor(environment)
	WeatherSky.apply(environment, WeatherState.rain, WeatherState.storm, WeatherState.clouds, current)
	if nightVision > 0 then
		-- (Night Vision: the ambients raised towards its grey.)
		local grey = Config.Effects.NightVisionAmbient
		local function lift(rgb: { number }): Color3
			local r, g, b = rgb[1], rgb[2], rgb[3]
			return Color3.fromRGB(
				r + math.max(0, grey - r) * nightVision,
				g + math.max(0, grey - g) * nightVision,
				b + math.max(0, grey - b) * nightVision
			)
		end
		write("Ambient", lift(environment.ambient))
		write("OutdoorAmbient", lift(environment.outdoorAmbient))
	else
		write("Ambient", colour(environment.ambient))
		write("OutdoorAmbient", colour(environment.outdoorAmbient))
	end
	write("Brightness", environment.brightness)
	write("ColorShift_Top", colour(environment.colorShiftTop))
	write("EnvironmentDiffuseScale", environment.environmentDiffuse)
	write("EnvironmentSpecularScale", environment.environmentSpecular)
	-- (Written while a short fog has it out of Lighting too, so it comes back up to date.)
	local atmosphere = ViewSettings.atmosphere()
	if atmosphere then
		AtmosphereModel.state(
			atmosphereState,
			environment,
			ViewSettings.lod() * BLOCK,
			ViewSettings.weatherFog(),
			current,
			ViewSettings.usesFog()
		)
		writeAtmosphere(atmosphere, atmosphereState)
	end
end

--[[
	The fog colour of the fluid the camera is in (Rendering/FluidFog), or with nil the place's own
	again (the Atmosphere is back by then); written at once.
]]
function LightingController.setFogColour(fog: Color3?)
	if fog and placeFogColour == nil then
		placeFogColour = Lighting.FogColor
	end
	fogOverride = fog
	if effectFog then
		-- (Blindness' black stays over the fluid's.)
		return
	elseif fog then
		write("FogColor", fog)
	elseif placeFogColour then
		write("FogColor", placeFogColour)
	end
end

--[[
	A status effect's fog colour (Blindness' black, Rendering/EffectView), or with nil the fluid's
	or the normal one again; written at once.
]]
function LightingController.setEffectFogColour(fog: Color3?)
	if fog and placeFogColour == nil then
		placeFogColour = Lighting.FogColor
	end
	effectFog = fog
	if fog then
		write("FogColor", fog)
	else
		LightingController.setFogColour(fogOverride)
	end
end

-- The haze follows a changed setting (the Fog setting, the view distance) at the next frame.
function LightingController.refresh()
	refreshed = true
end

-- Night Vision's scale (0: none .. 1; see the header): the ambients follow at the next frame.
function LightingController.setNightVision(scale: number)
	scale = math.clamp(scale, 0, 1)
	if math.abs(scale - nightVision) > 0.01 or (scale == 0) ~= (nightVision == 0) then
		nightVision = scale
		nightVisionChanged = true
	end
end

-- The day time now, in ticks (DayCycle), as the server's clock says (Config.Time.StartTime until
-- the server has published it).
function LightingController.dayTime(): number
	return DayCycle.now(
		attribute(DayCycle.ATTRIBUTE_TIME, Config.Time.StartTime),
		attribute(DayCycle.ATTRIBUTE_SYNC, 0),
		workspace:GetServerTimeNow(),
		attribute(DayCycle.ATTRIBUTE_RATE, 0)
	)
end

-- Sky light reaching the camera, 1 outdoors to 0 deep underground (smoothed), e.g. for F3 and the
-- music (Audio/Music: surface or cave).
function LightingController.skyExposure(): number
	return exposure or 1
end

--[[
	F3's fog line: the fog showing (ViewSettings.fogMode) and, for the Atmosphere, its Density
	(with how far things are 90% hazed), Haze, Glare and Offset as Lighting has them; the old
	fog's start and end (blocks) for the others.
]]
function LightingController.describeFog(): string
	local mode = ViewSettings.fogMode()
	local atmosphere = ViewSettings.atmosphere()
	if mode == "atmosphere" and atmosphere then
		local density = atmosphere.Density
		local reach = AtmosphereModel.reach(density, 0.9) / BLOCK
		return string.format(
			"fog     atmosphere%s  density %.3f (90%% at %s)  haze %.2f  glare %.2f  offset %.2f",
			if Config.Lighting.Enabled then "" else " (the place's)",
			density,
			if reach < 1e6 then string.format("%d", math.floor(reach + 0.5)) else "never",
			atmosphere.Haze,
			atmosphere.Glare,
			atmosphere.Offset
		)
	elseif mode == "none" then
		return "fog     none (the place's own)"
	end
	return string.format(
		"fog     %s  %.1f-%.1f blocks (Lighting fog%s)",
		mode,
		Lighting.FogStart / BLOCK,
		Lighting.FogEnd / BLOCK,
		if atmosphere then ", atmosphere out" else ""
	)
end

--[[
	Minecraft's sky light (0..15) at block cell (x, y, z), estimated from the client's blocks
	(SkyExposure.skyLight), for the cave mood (Audio/Ambience); nil where the cell isn't loaded or
	before `start` was given a generator and a world.
]]
function LightingController.skyLight(x: number, y: number, z: number): number?
	local blocks = getBlock
	if generator == nil or blocks == nil then
		return nil
	end
	return SkyExposure.skyLight(x, y, z, groundAt, blocks)
end

--[[
	Starts driving Lighting. `terrain` (the world's generator) gives the natural ground height for
	the underground fade (without it the sky's light is never faded), and `world` the blocks that
	tell an open pit or a tunnel near the surface from a cave (without it everything that deep
	counts as a cave).
]]
function LightingController.start(terrain: TerrainGenerator.Generator?, world: ClientWorld.ClientWorld?)
	assert(not started, "LightingController.start was already called")
	started = true
	generator = terrain
	if Config.Lighting.Enabled then
		-- The haze's Atmosphere and the Sky it needs (see the header).
		if Lighting:FindFirstChildOfClass("Sky") == nil then
			local sky = Instance.new("Sky")
			sky.Name = "IceVoxelSky"
			sky.Parent = Lighting
		end
		local atmosphere = ViewSettings.atmosphere()
		if atmosphere == nil then
			local created = Instance.new("Atmosphere")
			created.Name = "IceVoxelAtmosphere"
			-- (Its values are written by the update below, before the next frame.)
			created.Parent = Lighting
			ViewSettings.setAtmosphere(created)
			atmosphere = created
		end
		for _, child in Lighting:GetChildren() do
			if child:IsA("Atmosphere") and child ~= atmosphere then
				warn(`[IceVoxel] a second Atmosphere in Lighting ("{child.Name}") was taken out; IceVoxel drives one`)
				child.Parent = nil
			end
		end
	end
	if world then
		getBlock = function(x: number, y: number, z: number): number?
			return world:getBlock(x, y, z)
		end
	end

	-- The server set the clock: show it now rather than at the next update.
	local changed = false
	for _, name in { DayCycle.ATTRIBUTE_TIME, DayCycle.ATTRIBUTE_SYNC, DayCycle.ATTRIBUTE_RATE } do
		workspace:GetAttributeChangedSignal(name):Connect(function()
			changed = true
		end)
	end

	update(0)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if changed or nightVisionChanged or refreshed or elapsed >= Config.Lighting.UpdateInterval then
			changed = false
			nightVisionChanged = false
			refreshed = false
			update(elapsed)
			elapsed = 0
		end
	end)
end

return LightingController
