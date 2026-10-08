--!strict
--[[
	The view's haze as a Roblox Atmosphere (Lighting.Atmosphere), pure: Rendering/LightingController
	writes `state` into the Atmosphere IceVoxel drives, Rendering/ViewSettings asks `fog` which fog
	shows (tests/spec/Atmosphere checks both). The numbers are Config.Lighting.Atmosphere's.

	  Distance  an Atmosphere has no FogStart / FogEnd. A thing d studs from the camera lets
	            T = exp(-k d) of its light through, k = Scale x Density^4 per stud (an exponential
	            from the camera on, never quite opaque; Roblox publishes no formula, so Scale is a
	            Config knob, see Config.Lighting.Atmosphere for the source and how to calibrate it).
	            `extinction`: the k that leaves Edge of the light at the view distance, the old
	            fog's FogEnd (view x BlockSize x the weather's fog factor: rain, snow and thunder
	            bring it nearer, so the same rule gives them a denser haze, Density x factor^-1/4);
	            `density` turns k back into a Density (0..1), `haze` is how hazed a distance is.
	            k, not Density, is what blends: k ~ Density^4.
	  Caves     the haze fades things into the sky behind them, daylit even in a cave: k is scaled
	            by the sky exposure squared (Rendering/SkyExposure: 1 outdoors, 0 deep
	            underground), so cave walls stay clear and the sky's haze (Haze, Glare: DayCycle
	            .environment fades them out underground) goes with it. Both follow the exposure's
	            own smoothing (Config.Lighting.Underground.Seconds), and the weather's.
	  Colour    Roblox lights the haze by the sky itself (dark at night, warm towards a low sun),
	            so Color is DayCycle.environment's fog colour (Minecraft's day, dusk and night fog,
	            darker and bluer in rain and thunder: Weather/WeatherSky) raised to ColorFloor at
	            its brightest channel: Minecraft's near-black night fog would darken a dark sky's
	            haze twice. Decay, Haze and Glare are the environment's (blended by the time of
	            day, thickened by the weather). Offset stays Config's.
	  Off       the Fog setting off (or Config.Render.Fog false): Density, Haze and Glare 0, the
	            plain sky. An Atmosphere stays in Lighting all the same: Roblox's old fog only comes
	            back without one.
	  Mode      `fog`: which fog shows. Inside a fluid (Rendering/FluidFog) and under Blindness
	            (Rendering/EffectView) Minecraft's short fogs keep their exact distances with the
	            old Lighting fog (FogStart / FogEnd / FogColor), which Roblox only draws while no
	            Atmosphere is in Lighting: ViewSettings takes it out (Parent nil) in the same call
	            that writes those distances, and puts it back when they end, so no frame shows
	            both or neither. Without any Atmosphere (Config.Lighting.Enabled false in a place
	            that has none) the old view fog stays: FogEnd at the view, FogStart CLASSIC_START
	            of it.

	`state` fills a table it is given (`new`), so an update allocates nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)

local AtmosphereModel = {}

-- Where the old view fog starts, as a share of its end (without an Atmosphere).
AtmosphereModel.CLASSIC_START = 0.55

-- The fog showing: the Atmosphere, a fluid's or a status effect's short fog, the old view fog
-- without an Atmosphere, or none (the place's own FogStart / FogEnd).
export type Mode = "atmosphere" | "fluid" | "effect" | "classic" | "none"

-- A short fog, studs from the eye.
export type Span = { start: number, finish: number }

export type Settings = typeof(Config.Lighting.Atmosphere)

-- The Atmosphere's properties (colours { r, g, b } in 0..255).
export type State = {
	density: number,
	offset: number,
	haze: number,
	glare: number,
	color: { number },
	decay: { number },
}

-- A State to fill (`state`).
function AtmosphereModel.new(): State
	return { density = 0, offset = 0, haze = 0, glare = 0, color = { 0, 0, 0 }, decay = { 0, 0, 0 } }
end

--[[
	The extinction (per stud) that lets `edge` (0..1) of a thing's light through at `distance`
	studs: -ln(edge) / distance.
]]
function AtmosphereModel.extinction(distance: number, edge: number): number
	return -math.log(math.clamp(edge, 1e-4, 0.9999)) / math.max(distance, 1)
end

-- The Density (0..1) whose extinction is `k` per stud.
function AtmosphereModel.density(k: number, settings: Settings?): number
	local scale = (settings or Config.Lighting.Atmosphere).Scale
	if k <= 0 or scale <= 0 then
		return 0
	end
	return math.clamp((k / scale) ^ 0.25, 0, 1)
end

-- How hazed (0..1) a thing `distance` studs away is at Density `density`.
function AtmosphereModel.haze(distance: number, density: number, settings: Settings?): number
	local scale = (settings or Config.Lighting.Atmosphere).Scale
	return 1 - math.exp(-scale * density ^ 4 * math.max(distance, 0))
end

-- How far (studs) things are `share` (0..1) hazed at Density `density` (math.huge at 0).
function AtmosphereModel.reach(density: number, share: number, settings: Settings?): number
	local k = (settings or Config.Lighting.Atmosphere).Scale * density ^ 4
	if k <= 0 then
		return math.huge
	end
	return -math.log(1 - math.clamp(share, 0, 0.9999)) / k
end

--[[
	`out` (a list of three, 0..255) set to `rgb` with its brightest channel raised to `floor`
	(the hue kept; black stays black); returns `out`.
]]
function AtmosphereModel.lift(rgb: { number }, floor: number, out: { number }): { number }
	local r, g, b = rgb[1], rgb[2], rgb[3]
	local top = math.max(r, g, b)
	local scale = if top > 0 and top < floor then floor / top else 1
	out[1] = math.clamp(r * scale, 0, 255)
	out[2] = math.clamp(g * scale, 0, 255)
	out[3] = math.clamp(b * scale, 0, 255)
	return out
end

--[[
	The Atmosphere into `out` (returned) for: `environment` (DayCycle.environment after
	Weather/WeatherSky.apply), a view of `view` studs, the weather's fog factor `weather`
	(WeatherSky.fog: 1 clear, nearer in rain, snow and thunder), the sky `exposure` (0..1) and the
	Fog setting `on`. `settings` defaults to Config.Lighting.Atmosphere.
]]
function AtmosphereModel.state(
	out: State,
	environment: DayCycle.Environment,
	view: number,
	weather: number,
	exposure: number,
	on: boolean,
	settings: Settings?
): State
	local atmosphere = settings or Config.Lighting.Atmosphere
	if on then
		local reach = math.clamp(exposure, 0, 1)
		local k = AtmosphereModel.extinction(view * math.clamp(weather, 0.05, 1), atmosphere.Edge)
		out.density = AtmosphereModel.density(k * reach * reach, atmosphere)
		out.haze = math.clamp(environment.haze, 0, 10)
		out.glare = math.clamp(environment.glare, 0, 10)
	else
		out.density, out.haze, out.glare = 0, 0, 0
	end
	out.offset = math.clamp(atmosphere.Offset, 0, 1)
	AtmosphereModel.lift(environment.fogColor, atmosphere.ColorFloor, out.color)
	local decay = environment.decay
	out.decay[1], out.decay[2], out.decay[3] = decay[1], decay[2], decay[3]
	return out
end

--[[
	Which fog shows, and the old Lighting fog's start and end for it (studs; nil, nil: the place's
	own): a status effect's `effect` when it is nearer than the fluid's (or there is none), the
	fluid's `fluid`, else the Atmosphere when there is one (`atmosphere`), else the old view fog
	(`on`: the Fog setting) for a view of `view` studs times the weather's factor `weather`.
	The Atmosphere is in Lighting only in "atmosphere" mode (`attached`).
]]
function AtmosphereModel.fog(
	effect: Span?,
	fluid: Span?,
	atmosphere: boolean,
	on: boolean,
	view: number,
	weather: number
): (Mode, number?, number?)
	if effect and (fluid == nil or effect.finish < fluid.finish) then
		return "effect" :: Mode, effect.start, effect.finish
	elseif fluid then
		return "fluid" :: Mode, fluid.start, fluid.finish
	elseif atmosphere then
		return "atmosphere" :: Mode, nil, nil
	elseif on then
		local finish = view * weather
		return "classic" :: Mode, finish * AtmosphereModel.CLASSIC_START, finish
	end
	return "none" :: Mode, nil, nil
end

-- Is the Atmosphere in Lighting in `mode` (the old fog only shows without it)?
function AtmosphereModel.attached(mode: Mode): boolean
	return mode == "atmosphere"
end

return AtmosphereModel
