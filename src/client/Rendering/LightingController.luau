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
	  Fog        its colour follows the time while IceVoxel's fog is in use (ViewSettings.usesFog);
	             its distance is ViewSettings'.

	An Atmosphere or Sky in Lighting is left alone: Roblox lights both by the sun and moon itself.
	Config.Lighting.Enabled = false leaves everything but ClockTime to the place (the exposure is
	still worked out: the cave ambience and F3 read it). Values are written every
	Config.Lighting.UpdateInterval seconds, and only when they changed (outside sunrise, sunset and
	the underground fade only ClockTime does).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local SkyExposure = require(script.Parent.SkyExposure)
local ViewSettings = require(script.Parent.ViewSettings)

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
local lighting: any = Lighting

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

-- How much sky light should reach the camera now (SkyExposure.target).
local function targetExposure(): number
	local camera = workspace.CurrentCamera
	if camera == nil or generator == nil then
		return 1
	end
	local position = camera.CFrame.Position / BLOCK
	return SkyExposure.target(position.X, position.Y, position.Z, groundAt, getBlock, Config.Lighting.Underground)
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
	write("Ambient", colour(environment.ambient))
	write("OutdoorAmbient", colour(environment.outdoorAmbient))
	write("Brightness", environment.brightness)
	write("ColorShift_Top", colour(environment.colorShiftTop))
	write("EnvironmentDiffuseScale", environment.environmentDiffuse)
	write("EnvironmentSpecularScale", environment.environmentSpecular)
	if ViewSettings.usesFog() then
		write("FogColor", colour(environment.fogColor))
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

-- Sky light reaching the camera, 1 outdoors to 0 deep underground (smoothed), e.g. for F3.
function LightingController.skyExposure(): number
	return exposure or 1
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
		if changed or elapsed >= Config.Lighting.UpdateInterval then
			changed = false
			update(elapsed)
			elapsed = 0
		end
	end)
end

return LightingController
