--[[
	The view's haze as a Roblox Atmosphere (client Rendering/AtmosphereModel), pure: the density
	for each view distance (the documented exponential: the loaded terrain's edge 90% hazed, its
	far LOD nodes more, near terrain clear), the weather (denser by its fog factor, a thicker,
	darker haze, no glare), caves (thinner by the sky exposure, nothing deep down), the Fog setting
	off, the colours by the time of day (Minecraft's fog colours, the night's raised so the dark
	sky doesn't darken them twice), the LOD clouds at y 320, which fog shows when (the short fogs
	with the Atmosphere out of Lighting), and default.project.json's Atmosphere and Sky.
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

	t.test("atmosphere: rain, snow and thunder thicken the haze as a nearer view would", function()
		local clear = outdoors(2048)
		local rain = outdoors(2048, WeatherSky.fog(1, 0, false, 1))
		local snow = outdoors(2048, WeatherSky.fog(1, 0, true, 1))
		local storm = outdoors(2048, WeatherSky.fog(1, 1, false, 1))
		t.ok(rain.density > clear.density, "rain is denser")
		t.ok(snow.density > rain.density, "snow denser still (0.4)")
		t.ok(storm.density > rain.density, "thunder too (0.45)")
		-- The same edge rule for the old fog's nearer FogEnd: Density x factor^-1/4.
		local factor = Config.Weather.Fog.Rain
		t.near(rain.density, clear.density * factor ^ -0.25, 1e-9, "the equivalent density")
		t.near(AtmosphereModel.haze(2048 * BLOCK * factor, rain.density), 1 - EDGE, 1e-6, "90% at the rain's distance")
		-- Indoors the weather's factor goes back to 1 (WeatherSky.fog by the exposure).
		t.eq(WeatherSky.fog(1, 1, false, 0), 1)

		-- The storm's sky: more haze, darker colour, no glare round a sun behind the clouds.
		local base = DayCycle.environment(12785, 1)
		local wet = WeatherSky.apply(DayCycle.environment(12785, 1), 1, 1, 1, 1)
		local sky = Config.Weather.Sky
		t.near(wet.haze, base.haze + sky.Haze + sky.ThunderHaze, 1e-9, "haze up by the weather")
		t.eq(wet.glare, 0, "no glare in the rain")
		t.ok(base.glare > 0, "(the sunset has some)")
		local clearState = AtmosphereModel.state(AtmosphereModel.new(), base, 6144, 1, 1, true)
		local wetState = AtmosphereModel.state(AtmosphereModel.new(), wet, 6144, 0.45, 1, true)
		t.ok(wetState.color[1] < clearState.color[1], "a darker haze colour (Minecraft's rain fog)")
		t.ok(wetState.haze > clearState.haze)
		-- In a cave the weather changes nothing.
		local cave = WeatherSky.apply(DayCycle.environment(6000, 0), 1, 1, 1, 0)
		t.eq(cave.haze, 0, "no haze underground")
		t.eq(cave.glare, 0)
	end)

	t.test("atmosphere: caves thin it out with the sky exposure; the Fog setting off clears it", function()
		local outside = outdoors(2048)
		local half = outdoors(2048, 1, 0.5)
		local deep = outdoors(2048, 1, 0)
		t.eq(deep.density, 0, "deep underground: no haze over the cave walls")
		t.eq(deep.haze, 0, "and none on a sky that isn't seen")
		t.eq(deep.glare, 0)
		-- k follows the exposure squared (k ~ Density^4).
		local k = settings.Scale * outside.density ^ 4
		t.near(settings.Scale * half.density ^ 4, k * 0.25, 1e-12, "half the exposure: a quarter of k")
		local last = -1
		for exposure = 0, 1, 0.125 do
			local density = outdoors(2048, 1, exposure).density
			t.ok(density >= last, `thicker towards the surface ({exposure})`)
			last = density
		end
		-- A cave wall 30 blocks off at a cave mouth (exposure 0.5): barely hazed.
		t.ok(AtmosphereModel.haze(30 * BLOCK, half.density) < 0.01, "cave walls stay clear")

		local off = outdoors(2048, 0.45, 1, false)
		t.eq(off.density, 0, "off: no distance haze")
		t.eq(off.haze, 0, "and no haze on the sky")
		t.eq(off.glare, 0)
		t.eq(off.offset, settings.Offset)
	end)

	t.test("atmosphere: colours by the time of day, no night darkened twice, no glowing night", function()
		local light = Config.Lighting
		local noon = outdoors(2048)
		for i = 1, 3 do
			t.near(noon.color[i], light.Day.FogColor[i], 1e-9, "noon: Minecraft's day fog")
			t.near(noon.decay[i], light.Day.Decay[i], 1e-9, "the day's decay")
		end
		t.near(noon.haze, light.Day.Haze, 1e-9)
		t.eq(noon.glare, light.Day.Glare)
		t.eq(noon.offset, settings.Offset)

		local midnight = AtmosphereModel.state(AtmosphereModel.new(), DayCycle.environment(18000, 1), 6144, 1, 1, true)
		local night = light.Night.FogColor
		local top = math.max(night[1], night[2], night[3])
		t.ok(top < settings.ColorFloor, "(Minecraft's night fog is darker than the floor)")
		t.near(math.max(midnight.color[1], midnight.color[2], midnight.color[3]), settings.ColorFloor, 1e-9, "raised")
		t.near(midnight.color[1] / midnight.color[3], night[1] / night[3], 1e-9, "the same hue")
		t.ok(midnight.color[3] < noon.color[3], "still darker than the day's")
		t.eq(midnight.glare, 0, "no glow round the moon")
		t.ok(midnight.haze <= noon.haze, "no brighter haze at night")
		t.near(midnight.haze, light.Night.Haze, 1e-9)

		local sunset = AtmosphereModel.state(AtmosphereModel.new(), DayCycle.environment(12785, 1), 6144, 1, 1, true)
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
