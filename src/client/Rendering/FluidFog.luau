--!strict
--[[
	The view from inside a fluid: Minecraft 1.20.1's FogRenderer for the fluid the camera is in
	(Camera.getFluidInCamera), with each fluid's numbers from Shared/Fluids (`fogColor`,
	`fogStart`, `fogEnd`, in blocks).

	  Which fluid  `cameraFluid`: the fluid of the block at the camera (any level, cave twins too)
	               when the camera is below its surface (FluidState.getHeight: the whole block when
	               the same fluid is above, else its level's height). Third person counts where
	               the camera is, as in Minecraft.
	  Distances    `fog` (blocks from the eye): lava 0.25 .. 1 (spectators -8 .. half the view
	               distance), oil 0 .. 2, fuel -8 .. 32, water -8 .. 96 times the water vision
	               (`vision`: LocalPlayer.getWaterVision, 0.25 at least; it builds up over 600
	               ticks under water, 10 times faster for spectators, and drops 10 a tick out of
	               it: `stepVision`), never past the view distance. Roblox fog starts at 0 at the
	               nearest.
	  Colour       `colour` (`rgb`: the same as three numbers): the fluid's fog colour; water's
	               brightens towards its brightest hue with the vision (FogRenderer.setupColor
	               scales it by 1 / its largest channel); fluids that give no light darken with the
	               light around the camera (the sun's brightness times the sky light reaching the
	               camera: Rendering/LightingController), as Minecraft's fog follows the light; lava
	               glows anyway.
	  Tint         `tint`: a ColorCorrectionEffect ("IceVoxelFluidView" in Lighting) tints the
	               view towards the fluid's colour (TINT strength), so it shows even when the
	               place has an Atmosphere, which replaces Lighting's fog. Worked out once per
	               fluid.

	`start` works it out every frame after the camera moved, as numbers, and writes it only when
	it changed (the fluid, the fog to a tenth of a block, the colour): the fog through
	ViewSettings.setFluidFog and LightingController.setFogColour (both put the view distance's fog
	back once the camera leaves the fluid), the tint directly. A frame in an unchanging fluid makes
	no garbage. Everything but `start` is pure (tests/spec/LavaOilClient).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local Fluids = require(Shared.Fluids)

local FluidFog = {}

-- LocalPlayer.waterVisionTime: ticks to full vision, the first 100 of them its first 60%.
FluidFog.VISION_TICKS = 600
local VISION_RAMP = 100
-- Water's fog end at full vision (FogRenderer: 96 blocks) and the least share of it (0.25).
local MIN_VISION = 0.25
-- How strongly the view is tinted towards each fluid's colour (0: not at all).
FluidFog.TINT = table.freeze({
	[Fluids.WATER] = 0.12,
	[Fluids.LAVA] = 0.55,
	[Fluids.OIL] = 0.5,
	[Fluids.FUEL] = 0.3,
})
-- Fluids giving no light are never darker than this share of their colour.
local MIN_LIGHT = 0.15

export type GetBlock = (x: number, y: number, z: number) -> number?

local floor = math.floor
local fluidLut = Fluids.blockLut

--[[
	The fluid (Shared/Fluids id, 0 none) the camera at (x, y, z) (blocks) is in: the fluid of the
	block there when y is below its surface (the block's top when the same fluid is above).
]]
function FluidFog.cameraFluid(getBlock: GetBlock, x: number, y: number, z: number): number
	local bx, by, bz = floor(x), floor(y), floor(z)
	local block = getBlock(bx, by, bz)
	if block == nil or block < 0 or block >= Blocks.count then
		return 0
	end
	local fluid = buffer.readu8(fluidLut, block)
	if fluid == 0 then
		return 0
	end
	local above = getBlock(bx, by + 1, bz)
	local height = if above ~= nil
			and above >= 0
			and above < Blocks.count
			and buffer.readu8(fluidLut, above) == fluid
		then 1
		else buffer.readu8(Blocks.fluidHeightLut, block) / Blocks.FLUID_FULL
	return if y < by + height then fluid else 0
end

--[[
	LocalPlayer.waterVisionTime after one tick: up by 1 (spectators 10) with the eyes in water, up
	to VISION_TICKS; down by 10 out of it.
]]
function FluidFog.stepVision(ticks: number, inWater: boolean, spectator: boolean): number
	if inWater then
		return math.clamp(ticks + (if spectator then 10 else 1), 0, FluidFog.VISION_TICKS)
	end
	return math.clamp(ticks - 10, 0, FluidFog.VISION_TICKS)
end

-- LocalPlayer.getWaterVision for `ticks` of it (0..1): 60% over the first 100 ticks, then 40% more.
function FluidFog.vision(ticks: number): number
	if ticks >= FluidFog.VISION_TICKS then
		return 1
	end
	local first = math.clamp(ticks / VISION_RAMP, 0, 1)
	local second = if ticks < VISION_RAMP
		then 0
		else math.clamp((ticks - VISION_RAMP) / (FluidFog.VISION_TICKS - VISION_RAMP), 0, 1)
	return first * 0.6 + second * 0.39999998
end

--[[
	Where the fog of fluid `fluid` starts and ends (blocks from the eye; Roblox's start is at least
	0), for a spectator or not, with water vision `vision` (0..1) and a view distance of `view`
	blocks. nil, nil for no fluid.
]]
function FluidFog.fog(fluid: number, spectator: boolean, vision: number, view: number): (number?, number?)
	local record = Fluids.get(fluid)
	if record == nil then
		return nil, nil
	end
	local start, finish = record.fogStart, record.fogEnd
	if fluid == Fluids.LAVA and spectator then
		-- (FogRenderer: spectators see through lava, to half the view distance.)
		start, finish = -8, view * 0.5
	elseif fluid == Fluids.WATER then
		finish *= math.max(MIN_VISION, vision)
	end
	finish = math.min(finish, view)
	return math.max(0, start), math.max(finish, 0.01)
end

--[[
	The fog colour of fluid `fluid` as three numbers (0..255 each, whole), with water vision
	`vision` (0..1) and `light` (0..1: how much light reaches the camera); 0, 0, 0 for no fluid.
]]
function FluidFog.rgb(fluid: number, vision: number, light: number): (number, number, number)
	local record = Fluids.get(fluid)
	if record == nil then
		return 0, 0, 0
	end
	local c = record.fogColor
	local r, g, b = c[1], c[2], c[3]
	if fluid == Fluids.WATER then
		-- (FogRenderer.setupColor: towards the colour scaled to its brightest, by the vision.)
		local top = math.max(r, g, b, 1)
		local scale = 1 + (255 / top - 1) * math.clamp(vision, 0, 1)
		r, g, b = r * scale, g * scale, b * scale
	end
	if record.light == 0 then
		local shade = math.max(MIN_LIGHT, math.clamp(light, 0, 1))
		r, g, b = r * shade, g * shade, b * shade
	end
	return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
end

-- The fog colour of fluid `fluid` (`rgb` as a list), nil for no fluid.
function FluidFog.colour(fluid: number, vision: number, light: number): { number }?
	if Fluids.get(fluid) == nil then
		return nil
	end
	local r, g, b = FluidFog.rgb(fluid, vision, light)
	return { r, g, b }
end

-- Each fluid's tint (`tint`), worked out once: the frame asks for it every frame.
local NO_TINT = table.freeze({ 255, 255, 255 })
local tints: { [number]: { number } } = {}
for fluid, strength in FluidFog.TINT do
	local record = Fluids.get(fluid)
	if record then
		local c = record.color
		local function mix(channel: number): number
			return math.floor(255 + (channel - 255) * strength + 0.5)
		end
		tints[fluid] = table.freeze({ mix(c[1]), mix(c[2]), mix(c[3]) })
	end
end

-- The ColorCorrectionEffect tint for fluid `fluid` (0..255 each, frozen): white (no tint) for none.
function FluidFog.tint(fluid: number): { number }
	return tints[fluid] or NO_TINT
end

--[[
	Starts applying the fluid view every frame, after the camera. `getBlock` reads the client's
	blocks; `isSpectator` says whether the local player spectates; `light` how much light reaches
	the camera (0..1); `setFog(start, finish)` (studs, nil: the normal fog again) and
	`setFogColour(colour)` (nil: the normal colour again) change the fog; `viewDistance` gives the
	view distance in blocks.
]]
function FluidFog.start(
	getBlock: GetBlock,
	isSpectator: () -> boolean,
	light: () -> number,
	setFog: (start: number?, finish: number?) -> (),
	setFogColour: (colour: Color3?) -> (),
	viewDistance: () -> number
)
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "IceVoxelFluidView"
	effect.Enabled = false
	effect.Parent = Lighting

	-- The fluid shown (0: none) and the fog and colour last written for it (a tenth of a block,
	-- whole colour steps).
	local current = 0
	local shownStart, shownFinish, shownR, shownG, shownB = 0, 0, 0, 0, 0
	-- Each fluid's tint as a Color3.
	local tintColours: { [number]: Color3 } = {}
	for fluid = 1, Fluids.COUNT do
		local rgb = FluidFog.tint(fluid)
		tintColours[fluid] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	local visionTicks = 0
	local clock = 0
	local tick = 1 / 20
	RunService:BindToRenderStep("IceVoxelFluidView", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end
		local at = camera.CFrame.Position / Config.BlockSize
		local fluid = FluidFog.cameraFluid(getBlock, at.X, at.Y, at.Z)
		local spectator = isSpectator()
		clock = math.min(clock + dt, tick * 5)
		while clock >= tick do
			clock -= tick
			visionTicks = FluidFog.stepVision(visionTicks, fluid == Fluids.WATER, spectator)
		end
		if fluid == 0 then
			if current ~= 0 then
				current = 0
				effect.Enabled = false
				setFog(nil, nil)
				setFogColour(nil)
			end
			return
		end
		-- (Numbers only, compared with what was written: a frame that changes nothing allocates
		-- nothing.)
		local vision = FluidFog.vision(visionTicks)
		local start, finish = FluidFog.fog(fluid, spectator, vision, viewDistance())
		local fogStart, fogFinish = math.floor((start or 0) * 10), math.floor((finish or 0) * 10)
		local r, g, b = FluidFog.rgb(fluid, vision, light())
		if fluid ~= current then
			effect.TintColor = tintColours[fluid]
			effect.Enabled = true
		elseif fogStart == shownStart and fogFinish == shownFinish and r == shownR and g == shownG and b == shownB then
			return
		end
		current = fluid
		shownStart, shownFinish, shownR, shownG, shownB = fogStart, fogFinish, r, g, b
		setFog((start or 0) * Config.BlockSize, (finish or 0) * Config.BlockSize)
		setFogColour(Color3.fromRGB(r, g, b))
	end)
end

-- The light reaching a camera for `dayTime` and the sky `exposure` (0..1): the sun's brightness
-- (0.2 at night) times the exposure.
function FluidFog.light(dayTime: number, exposure: number): number
	return DayCycle.sunBrightness(dayTime) * math.clamp(exposure, 0, 1)
end

return FluidFog
