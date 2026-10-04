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
	             generator's height of the camera's column), unless nothing opaque is above the
	             camera (a pit or shaft open to the sky; checked in the client's block data). Caves
	             never open to the surface, so nothing that should be sunlit is darkened.
	  Fog        its colour follows the time while IceVoxel's fog is in use (ViewSettings.usesFog);
	             its distance is ViewSettings'.

	An Atmosphere or Sky in Lighting is left alone: Roblox lights both by the sun and moon itself.
	Config.Lighting.Enabled = false leaves everything but ClockTime to the place. Values are
	written every Config.Lighting.UpdateInterval seconds, and only when they changed (outside
	sunrise, sunset and the underground fade only ClockTime does).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ViewSettings = require(script.Parent.ViewSettings)

local BLOCK = Config.BlockSize
-- Blocks above the natural ground still searched for a roof over an open pit (player builds).
local ROOF_MARGIN = 64

local LightingController = {}

local started = false
local generator: TerrainGenerator.Generator? = nil
local blocks: ClientWorld.ClientWorld? = nil
-- Sky light reaching the camera, smoothed (1 outdoors, 0 deep underground); nil before the first
-- update, which takes the target at once.
local exposure: number? = nil
-- The column the camera was last above or below, and its natural ground height (blocks).
local columnX, columnZ, columnGround = math.huge, math.huge, 0
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

-- The natural ground height (first air block) of the column at block (x, z), cached per column.
local function groundAt(terrain: TerrainGenerator.Generator, x: number, z: number): number
	local bx, bz = math.floor(x), math.floor(z)
	if bx ~= columnX or bz ~= columnZ then
		columnX, columnZ = bx, bz
		columnGround = (terrain.column(bx, bz))
	end
	return columnGround
end

-- Is nothing opaque above block (x, y, z), up to `top`? Unknown (unloaded) blocks count as a roof.
local function openToSky(world: ClientWorld.ClientWorld, x: number, y: number, z: number, top: number): boolean
	for cell = y, top do
		local block = world:getBlock(x, cell, z)
		if block == nil or Blocks.isOpaque(block) then
			return false
		end
	end
	return true
end

-- How much sky light should reach the camera now (DayCycle.skyExposure).
local function targetExposure(): number
	local camera = workspace.CurrentCamera
	local terrain = generator
	if camera == nil or terrain == nil then
		return 1
	end
	local position = camera.CFrame.Position / BLOCK
	local ground = groundAt(terrain, position.X, position.Z)
	local underground = Config.Lighting.Underground
	local target = DayCycle.skyExposure(ground - position.Y, underground.Start, underground.End)
	local world = blocks
	if target < 1 and world then
		local x, y, z = math.floor(position.X), math.floor(position.Y), math.floor(position.Z)
		if openToSky(world, x, y, z, math.min(ground + ROOF_MARGIN, Config.WorldHeight - 1)) then
			return 1
		end
	end
	return target
end

local function update(dt: number)
	local dayTime = LightingController.dayTime()
	write("ClockTime", DayCycle.clockTime(dayTime))
	local settings = Config.Lighting
	if not settings.Enabled then
		return
	end

	local current = DayCycle.approach(exposure, targetExposure(), dt, settings.Underground.Seconds)
	exposure = current

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
	tell an open pit from a cave (without it everything that deep counts as a cave).
]]
function LightingController.start(terrain: TerrainGenerator.Generator?, world: ClientWorld.ClientWorld?)
	assert(not started, "LightingController.start was already called")
	started = true
	generator = terrain
	blocks = world

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
