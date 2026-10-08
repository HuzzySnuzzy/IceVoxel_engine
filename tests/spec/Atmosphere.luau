--[[
	The view's haze as a Roblox Atmosphere (client Rendering/AtmosphereModel), pure: the density
	for each view distance (the documented exponential: the loaded terrain's edge 90% hazed, its
	far LOD nodes more, near terrain clear), the weather (denser by a share of its fog factor that
	keeps the storm clouds overhead, a thicker, darker haze, no glare), caves (thinner below
	ThinBelow of sky exposure, nothing deep down, the full haze out of a tunnel's mouth), the Fog
	setting off, the colours by the time of day (Minecraft's fog colours; a ColorFloor goes on
	before the weather darkens them; no glare once the sun is down), the LOD clouds at y 320, which
	fog shows when (the short fogs with the Atmosphere out of Lighting), and default.project.json's
	Atmosphere (marked as the project's) and Sky.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local AtmosphereModel = require(client.Rendering.AtmosphereModel)
	local WeatherSky = require(client.Weather.WeatherSky)
	local CloudLod = require(client.Weather.CloudLod)

	local BLOCK = Config.BlockSize
	local settings = Config.Lighting.Atmosphere
	local EDGE = settings.Edge
	-- The presets' view distances (Low on phones, Medium, High, Ultra) and the slider's least.
	local VIEWS = { 256, 512, 1024, 2048, 4096 }

	-- The Atmosphere at noon, outdoors, clear, for a view of `view` blocks (weather factor `weather`).
	local function outdoors(view: number, weather: number?, exposure: number?, on: boolean?): any
		local environment = DayCycle.environment(6000, exposure or 1)
		return AtmosphereModel.state(
			AtmosphereModel.new(),
			environment,
			view * BLOCK,
			weather or 1,
			exposure or 1,
			if on == nil then true else on
		)
	end

	--[[ Distance ]]

	t.test("atmosphere: the density hides the view distance's edge and keeps the near view clear", function()
		local last = math.huge
		for _, view in VIEWS do
			local density = outdoors(view).density
			local edge = view * BLOCK
			t.ok(density > 0 and density < 1, `a density for {view} blocks ({density})`)
			t.ok(density < last, `a longer view, a thinner haze ({view})`)
			last = density
			-- The edge of the loaded terrain is (1 - Edge) hazed, as the old fog's FogEnd hid it.
			t.near(AtmosphereModel.haze(edge, density), 1 - EDGE, 1e-6, `90% at the edge ({view})`)
			t.near(AtmosphereModel.reach(density, 1 - EDGE), edge, 1e-6, "reach is haze's inverse")
			-- LodTree draws nodes partly inside whole: up to a third further they fade more.
			t.ok(AtmosphereModel.haze(edge * 4 / 3, density) > 0.95, `the far LOD overhang ({view})`)
			-- Near terrain stays clear: the exponential's shape, whatever the constant.
			t.ok(AtmosphereModel.haze(edge / 40, density) < 0.06, `clear nearby ({view})`)
			t.near(AtmosphereModel.haze(edge / 4, density), 1 - EDGE ^ 0.25, 1e-9, "a quarter of the way")
			-- The relation itself: T = exp(-Scale x Density^4 x d).
			t.near(
				AtmosphereModel.haze(1000, density),
				1 - math.exp(-settings.Scale * density ^ 4 * 1000),
				1e-12,
				"Scale x Density^4"
			)
		end
		-- The numbers in Config's comment.
		t.near(outdoors(2048).density, 0.247, 0.001, "High")
		t.near(outdoors(1024).density, 0.294, 0.001, "Medium")
		t.near(outdoors(512).density, 0.350, 0.001, "Low")
		t.near(outdoors(4096).density, 0.208, 0.001, "Ultra")
		-- What the default view leaves clear: full detail's edge and a hill 64 blocks off.
		local density = outdoors(Config.Lod.ViewDistance).density
		t.ok(AtmosphereModel.haze(64 * BLOCK, density) < 0.08, "64 blocks: under 8%")
		t.ok(AtmosphereModel.haze(32 * BLOCK, density) < 0.04, "32 blocks: under 4%")
		-- Density and extinction are each other's inverse; nothing at k 0.
		local k = AtmosphereModel.extinction(6144, EDGE)
		t.near(settings.Scale * AtmosphereModel.density(k) ^ 4, k, 1e-12, "k = Scale x Density^4")
		t.eq(AtmosphereModel.density(0), 0)
		t.eq(AtmosphereModel.reach(0, 0.9), math.huge, "no haze, no reach")
		t.ok(AtmosphereModel.density(1e9) == 1, "clamped to Roblox's range")
	end)

	t.test("atmosphere: rain, snow and thunder thicken the haze, the storm clouds overhead stay", function()
		local clear = outdoors(2048)
		local rain = outdoors(2048, WeatherSky.fog(1, 0, false, 1))
		local snow = outdoors(2048, WeatherSky.fog(1, 0, true, 1))
		local storm = outdoors(2048, WeatherSky.fog(1, 1, false, 1))
		t.ok(rain.density > clear.density, "rain is denser")
		t.ok(snow.density > rain.density, "snow denser still (0.4)")
		t.ok(storm.density > rain.density, "thunder too (0.45)")
		-- The edge rule for a view the factor to WeatherPower as far: Density x factor^(-power/4).
		local factor, power = Config.Weather.Fog.Rain, settings.WeatherPower
		t.ok(power > 0 and power < 1, "a share of the old fog's nearer FogEnd")
		t.near(rain.density, clear.density * factor ^ (-power / 4), 1e-9, "the equivalent density")
		t.near(
			AtmosphereModel.haze(2048 * BLOCK * factor ^ power, rain.density),
			1 - EDGE,
			1e-6,
			"90% at the rain's distance"
		)
		-- Indoors the weather's factor goes back to 1 (WeatherSky.fog by the exposure).
		t.eq(WeatherSky.fog(1, 1, false, 0), 1)

		-- The haze starts at the camera: the storm's cloud deck overhead (Drop lower, a camera at
		-- y 64) stays at most half hazed into the clear sky behind it from 1024 blocks up, where
		-- the old fog (from 55% of its FogEnd) never reached it. The whole factor would wash the
		-- rain clouds out.
		local clouds = Config.Weather.Clouds
		local overhead = (clouds.Altitude - clouds.Drop - 64) * BLOCK
		local whole = table.clone(settings)
		whole.WeatherPower = 1
		for _, view in { 1024, 2048, 4096 } do
			for _, weather in
				{ WeatherSky.fog(1, 0, false, 1), WeatherSky.fog(1, 0, true, 1), WeatherSky.fog(1, 1, false, 1) }
			do
				local density = outdoors(view, weather).density
				t.ok(AtmosphereModel.haze(overhead, density) <= 0.5, `storm clouds overhead at {view} ({weather})`)
				t.ok(
					AtmosphereModel.haze(view * BLOCK, density) >= 1 - EDGE,
					`the edge hazed at least as much ({view})`
				)
			end
			local washed = AtmosphereModel.state(
				AtmosphereModel.new(),
				DayCycle.environment(6000, 1),
				view * BLOCK,
				Config.Weather.Fog.Snow,
				1,
				true,
				whole
			)
			if view == 1024 then
				t.ok(AtmosphereModel.haze(overhead, washed.density) > 0.6, "(the whole factor: washed out)")
			end
		end

		-- The storm's sky: more haze, darker colour, no glare round a sun behind the clouds (the
		-- sun low, a little before it sets).
		local base = DayCycle.environment(12500, 1)
		local wet = WeatherSky.apply(DayCycle.environment(12500, 1), 1, 1, 1, 1)
		local sky = Config.Weather.Sky
		t.near(wet.haze, base.haze + sky.Haze + sky.ThunderHaze, 1e-9, "haze up by the weather")
		t.eq(wet.glare, 0, "no glare in the rain")
		t.ok(base.glare > 0, "(the sunset has some)")
		local clearState = AtmosphereModel.state(AtmosphereModel.new(), base, 6144, 1, 1, true)
		local wetState = AtmosphereModel.state(AtmosphereModel.new(), wet, 6144, 0.45, 1, true)
		t.ok(wetState.color[1] < clearState.color[1], "a darker haze colour (Minecraft's rain fog)")
		t.ok(wetState.haze > clearState.haze)
		-- Darker by Minecraft's rain and thunder at any time, the night too, with or without a
		-- ColorFloor: it goes on the time of day's colour, before the weather darkens it.
		local floored = table.clone(settings)
		floored.ColorFloor = 96
		for _, floor in { settings, floored } do
			for _, dayTime in { 6000, 12785, 18000 } do
				local function colour(rain: number, thunder: number): { number }
					local environment = AtmosphereModel.floor(DayCycle.environment(dayTime, 1), floor)
					WeatherSky.apply(environment, rain, thunder, math.max(rain, thunder), 1)
					return AtmosphereModel.state(AtmosphereModel.new(), environment, 6144, 1, 1, true, floor).color
				end
				local dry, rainy, thundery = colour(0, 0), colour(1, 0), colour(1, 1)
				for i = 1, 3 do
					t.ok(rainy[i] < dry[i], `rain darkens it ({dayTime}, floor {floor.ColorFloor})`)
					t.ok(thundery[i] < rainy[i], `thunder more ({dayTime}, floor {floor.ColorFloor})`)
				end
				-- Minecraft's own factors on whatever the time of day gave.
				t.near(thundery[1] / dry[1], 0.25, 1e-9, "red and green: (1 - 0.5) x (1 - 0.5)")
				t.near(thundery[3] / dry[3], 0.3, 1e-9, "blue: (1 - 0.4) x (1 - 0.5)")
			end
		end
		-- In a cave the weather changes nothing.
		local cave = WeatherSky.apply(DayCycle.environment(6000, 0), 1, 1, 1, 0)
		t.eq(cave.haze, 0, "no haze underground")
		t.eq(cave.glare, 0)
	end)

	t.test("atmosphere: caves thin it out with the sky exposure; the Fog setting off clears it", function()
		local outside = outdoors(2048)
		local thin = settings.ThinBelow
		local half = outdoors(2048, 1, thin / 2)
		local deep = outdoors(2048, 1, 0)
		t.eq(deep.density, 0, "deep underground: no haze over the cave walls")
		t.eq(deep.haze, 0, "and none on a sky that isn't seen")
		t.eq(deep.glare, 0)
		-- Below ThinBelow k follows (exposure / ThinBelow)^2 (k ~ Density^4).
		local k = settings.Scale * outside.density ^ 4
		t.near(settings.Scale * half.density ^ 4, k * 0.25, 1e-12, "half of ThinBelow: a quarter of k")
		t.near(outdoors(2048, 1, thin).density, outside.density, 1e-12, "from ThinBelow up: all of it")
		local last = -1
		for exposure = 0, 1, 0.125 do
			local density = outdoors(2048, 1, exposure).density
			t.ok(density >= last, `thicker towards the surface ({exposure})`)
			last = density
		end
		-- A deep cave's walls 30 blocks off (exposure 0.1) stay clear, even on Low's denser haze.
		for _, view in { 512, 1024, 2048, 4096 } do
			t.ok(
				AtmosphereModel.haze(30 * BLOCK, outdoors(view, 1, 0.1).density) < 0.01,
				`cave walls stay clear ({view})`
			)
		end
		-- Looking out of a tunnel dug into a hillside (SkyExposure: 1 - distance / End) the view's
		-- edge stays hazed as outdoors for the first 9 blocks, so the stepping out doesn't pump
		-- the haze; its walls, within End blocks, are too near to haze much anyway.
		local finish = Config.Lighting.Underground.End
		for inside = 0, 9 do
			local density = outdoors(2048, 1, 1 - inside / finish).density
			t.near(density, outside.density, 1e-12, `the full haze {inside} blocks in`)
			t.ok(AtmosphereModel.haze(finish * BLOCK, density) < 0.03, "the tunnel's walls barely")
		end
		t.ok(AtmosphereModel.haze(2048 * BLOCK, outdoors(2048, 1, 1 - 10 / finish).density) > 0.85, "10 blocks in")

		local off = outdoors(2048, 0.45, 1, false)
		t.eq(off.density, 0, "off: no distance haze")
		t.eq(off.haze, 0, "and no haze on the sky")
		t.eq(off.glare, 0)
		t.eq(off.offset, settings.Offset)
	end)

	t.test("atmosphere: colours by the time of day, a dark night, no glare once the sun is down", function()
		local light = Config.Lighting
		local noon = outdoors(2048)
		for i = 1, 3 do
			t.near(noon.color[i], light.Day.FogColor[i], 1e-9, "noon: Minecraft's day fog")
			t.near(noon.decay[i], light.Day.Decay[i], 1e-9, "the day's decay")
		end
		t.near(noon.haze, light.Day.Haze, 1e-9)
		t.eq(noon.glare, light.Day.Glare)
		t.eq(noon.offset, settings.Offset)

		-- The night: Minecraft's own night fog (Roblox scatters the sky's light into the haze by
		-- Color, undarkened at night as far as the re-implementation shows; a bright Color would
		-- glow over the dark sky).
		local function at(dayTime: number, floor: any?): any
			local environment = AtmosphereModel.floor(DayCycle.environment(dayTime, 1), floor)
			return AtmosphereModel.state(AtmosphereModel.new(), environment, 6144, 1, 1, true, floor)
		end
		local midnight = at(18000)
		local night = light.Night.FogColor
		t.eq(settings.ColorFloor, 0, "no floor by default")
		for i = 1, 3 do
			t.near(midnight.color[i], night[i], 1e-9, "midnight: Minecraft's night fog")
		end
		t.eq(midnight.glare, 0, "no glow round the moon")
		t.ok(midnight.haze <= noon.haze, "no brighter haze at night")
		t.near(midnight.haze, light.Night.Haze, 1e-9)
		-- A ColorFloor (a knob for the Roblox player) raises the night's brightest channel, same hue.
		local floored = table.clone(settings)
		floored.ColorFloor = 96
		local raised = at(18000, floored)
		t.near(math.max(raised.color[1], raised.color[2], raised.color[3]), 96, 1e-9, "raised")
		t.near(raised.color[1] / raised.color[3], night[1] / night[3], 1e-9, "the same hue")
		for i = 1, 3 do
			t.near(at(6000, floored).color[i], light.Day.FogColor[i], 1e-9, "the day's left alone")
		end

		-- The dusk glare only with the sun above the horizon: once it has set (and before it rises)
		-- Roblox may light from the moon, which would glow. The haze keeps the dusk's glow.
		local sunset = DayCycle.environment(12500, 1)
		t.ok(DayCycle.sunHeight(12500) > 0 and sunset.glare > 0.2, "a glow round the setting sun")
		for _, tick in { 12785, 13000, 13250, 13500, 22800, 23000 } do
			local after = DayCycle.environment(tick, 1)
			t.ok(DayCycle.sunHeight(tick) <= 0.001, `(the sun is down at {tick})`)
			t.ok(after.glare < 1e-3, `no glare with the sun down ({tick}: {after.glare})`)
		end
		t.ok(DayCycle.environment(13000, 1).haze > noon.haze, "the warm haze stays after sunset")
		for _, height in { -0.3, -0.2, -0.1, -0.01, 0 } do
			t.eq(DayCycle.environment(12000, 1, nil, height).glare, 0, `none at sun height {height}`)
		end
		t.ok(DayCycle.environment(12000, 1, nil, DayCycle.GLARE_RISE).glare > 0.25, "full by GLARE_RISE")

		local sunset = AtmosphereModel.state(AtmosphereModel.new(), DayCycle.environment(12500, 1), 6144, 1, 1, true)
		t.ok(sunset.color[1] > sunset.color[3], "a warm horizon at sunset")
		t.ok(sunset.haze > noon.haze, "more haze along it")
		t.ok(sunset.glare > 0, "a glow round the low sun")
		t.ok(sunset.decay[3] > sunset.decay[1], "cooler away from it")

		-- The lift keeps black black and leaves bright colours alone.
		local out = { 0, 0, 0 }
		AtmosphereModel.lift({ 0, 0, 0 }, 96, out)
		t.eq(out[1] + out[2] + out[3], 0)
		AtmosphereModel.lift({ 200, 100, 50 }, 96, out)
		t.eq(out[1], 200)
		t.eq(out[3], 50)
		-- One table, filled again: an update allocates nothing.
		local state = AtmosphereModel.new()
		local colour = state.color
		t.eq(AtmosphereModel.state(state, DayCycle.environment(0, 1), 6144, 1, 1, true), state)
		t.eq(state.color, colour, "the colour list kept")
	end)

	t.test("atmosphere: the LOD clouds at y 320 fade at the edge, not halfway", function()
		local clouds = Config.Weather.Clouds
		for _, view in { 1024, 2048, 4096 } do
			local density = outdoors(view).density
			local cloudSettings = CloudLod.settings(CloudLod.FANCY, view)
			local outer = cloudSettings.cell * 2 ^ (CloudLod.levels(cloudSettings) - 1)
			-- A camera on the ground at y 64, clouds at the Altitude.
			local height = clouds.Altitude - 64
			local function hazed(horizontal: number): number
				return AtmosphereModel.haze(math.sqrt(horizontal ^ 2 + height ^ 2) * BLOCK, density)
			end
			t.ok(hazed(view + outer * 0.71) >= 1 - EDGE, `the rings' ragged edge melts into the sky ({view})`)
			-- (Measured along the line of sight, the cloud's height included.)
			local half = math.sqrt(math.max(0, (view / 2) ^ 2 - height ^ 2))
			t.ok(hazed(half) < 0.7, `halfway out a cloud still shows ({view})`)
			t.ok(hazed(0) < 0.5, `overhead: more cloud than haze ({view})`)
		end
		-- The phones' 512 blocks: a denser haze, the clouds overhead fainter (as Minecraft's fog
		-- closes over its clouds at a short render distance), still there.
		local low = outdoors(512).density
		local overhead = AtmosphereModel.haze((clouds.Altitude - 64) * BLOCK, low)
		t.ok(overhead > 0.5 and overhead < 0.75, `Low: clouds overhead {overhead}`)
	end)

	--[[ Which fog shows ]]

	t.test("atmosphere: the short fogs take over from the Atmosphere, the nearer one wins", function()
		local lava = { start = 0.25 * BLOCK, finish = 1 * BLOCK }
		local water = { start = 0, finish = 96 * BLOCK }
		local blind = { start = 1.25 * BLOCK, finish = 5 * BLOCK }
		local view = 2048 * BLOCK
		local mode, start, finish = AtmosphereModel.fog(nil, nil, true, true, view, 1)
		t.eq(mode, "atmosphere")
		t.eq(start, nil, "the old fog: the place's own")
		t.eq(finish, nil)
		t.ok(AtmosphereModel.attached(mode), "the Atmosphere in Lighting")
		mode, start, finish = AtmosphereModel.fog(nil, lava, true, true, view, 1)
		t.eq(mode, "fluid")
		t.eq(start, lava.start, "Minecraft's lava fog, exactly")
		t.eq(finish, lava.finish)
		t.ok(not AtmosphereModel.attached(mode), "the Atmosphere out: Roblox draws the old fog")
		mode, _, finish = AtmosphereModel.fog(blind, lava, true, true, view, 1)
		t.eq(mode, "fluid", "lava's 1 block is nearer than Blindness' 5")
		t.eq(finish, lava.finish)
		mode, start, finish = AtmosphereModel.fog(blind, water, true, true, view, 1)
		t.eq(mode, "effect", "Blindness under water")
		t.eq(start, blind.start)
		t.eq(finish, blind.finish)
		t.ok(not AtmosphereModel.attached(mode))
		mode = AtmosphereModel.fog(blind, nil, true, false, view, 1)
		t.eq(mode, "effect", "whatever the Fog setting")
		mode = AtmosphereModel.fog(nil, water, true, false, view, 1)
		t.eq(mode, "fluid")
		mode = AtmosphereModel.fog(nil, nil, true, false, view, 1)
		t.eq(mode, "atmosphere", "off: the Atmosphere stays, at density 0")
		-- Without an Atmosphere: the old view fog, nearer in rain; off, the place's own.
		mode, start, finish = AtmosphereModel.fog(nil, nil, false, true, view, 0.6)
		t.eq(mode, "classic")
		t.eq(finish, view * 0.6)
		t.eq(start, view * 0.6 * AtmosphereModel.CLASSIC_START)
		t.ok(not AtmosphereModel.attached(mode))
		mode, start = AtmosphereModel.fog(nil, nil, false, false, view, 1)
		t.eq(mode, "none")
		t.eq(start, nil)
	end)

	--[[ The place ]]

	t.test("atmosphere: default.project.json has a Sky and the Atmosphere's daytime values", function()
		local project = serde.decode("json", fs.readFile("default.project.json"))
		local lighting = project.tree.Lighting
		t.eq(lighting.Sky and lighting.Sky["$className"], "Sky", "a Sky: Roblox ignores an Atmosphere without one")
		local atmosphere = lighting.Atmosphere
		t.eq(atmosphere and atmosphere["$className"], "Atmosphere")
		-- Marked as IceVoxel's (ViewSettings.PROJECT_ATTRIBUTE): taken out with Lighting.Enabled
		-- false, where IceVoxel drives no Atmosphere and the old view fog follows the view.
		t.eq(atmosphere["$attributes"] and atmosphere["$attributes"].IceVoxel, true, "the project's own")
		local properties = atmosphere["$properties"]
		-- The project's ClockTime is past sunrise's glow: the day's values, as the client sets them.
		t.ok(DayCycle.glow(math.sin(math.rad((lighting["$properties"].ClockTime - 6) * 15))) == 0, "full day")
		local day = outdoors(Config.Lod.ViewDistance)
		t.near(properties.Density, day.density, 0.0005, "Density")
		t.near(properties.Offset, day.offset, 1e-9, "Offset")
		t.near(properties.Haze, day.haze, 1e-9, "Haze")
		t.near(properties.Glare, day.glare, 1e-9, "Glare")
		for i = 1, 3 do
			t.near(properties.Color[i] * 255, day.color[i], 0.6, "Color")
			t.near(properties.Decay[i] * 255, day.decay[i], 0.6, "Decay")
		end
		-- Every property set, as Roblox's reflection defaults change between builds.
		for _, name in { "Density", "Offset", "Color", "Decay", "Glare", "Haze" } do
			t.ok(properties[name] ~= nil, `{name} set`)
		end
	end)
end
