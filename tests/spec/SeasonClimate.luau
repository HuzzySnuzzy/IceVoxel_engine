--[[
	What the seasons do to the climate (Shared/Seasons/SeasonClimate over Tough As Nails' Temperature):
	the biome classes and amplitudes, the target table of the seasons' design (plains, birch forest,
	taiga, savanna and desert by day, by night and under a roof at night, a summer roof by day and a
	heat wave), heat waves (deterministic, summer only, never two in a row), the snow caps, the melt
	rule, the far landscape's cover (and when the season's snow thaws with it) and the identity
	with the seasons off.
]]

return function(t, shared, require)
	local Config = require(shared.Config)
	local Biomes = require(shared.Biomes)
	local Calendar = require(shared.Seasons.Calendar)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local Weather = require(shared.Weather)

	local DAY = 24000

	local function state(): any
		local s = Calendar.newState()
		s.enabled = true
		return s
	end

	local function env(climate: number, sample: any, night: boolean, skyOpen: boolean): Temperature.Environment
		return {
			climate = climate,
			y = 70,
			surface = 70,
			skyOpen = skyOpen,
			night = night,
			wet = false,
			sprinting = false,
			heated = false,
			nearHeat = false,
			cooled = false,
			burning = false,
			armorWarmth = 0,
			armorCooling = 0,
			seasonShift = sample.shift,
			nightDrop = sample.nightDrop,
		}
	end

	t.test("season climate: the biome classes and their amplitudes", function()
		local expected = {
			Tundra = "cold",
			Taiga = "cold",
			OldGrowthTaiga = "cold",
			Grove = "cold",
			SnowySlopes = "cold",
			JaggedPeaks = "cold",
			FrozenPeaks = "cold",
			Desert = "dry",
			Savanna = "dry",
			WindsweptSavanna = "dry",
			Jungle = "tropical",
			MushroomFields = "tropical",
			Plains = "temperate",
			Forest = "temperate",
			BirchForest = "temperate",
			WindsweptHills = "temperate",
			Meadow = "temperate",
			StonyPeaks = "temperate",
		}
		for name, class in expected do
			local biome = assert(Biomes.byName(name), name)
			t.eq(SeasonClimate.classOf(biome.index), class, name)
		end
		t.eq(SeasonClimate.amplitude("cold"), 1)
		t.eq(SeasonClimate.amplitude("temperate"), 1)
		t.eq(SeasonClimate.amplitude("dry"), 0.75)
		t.eq(SeasonClimate.amplitude("tropical"), 0.5)
		t.eq(SeasonClimate.SNOW_BELOW, Weather.SNOW_BELOW, "Weather's snow border, copied")
		t.eq(SeasonClimate.NIGHT, Temperature.NIGHT, "Temperature's night drop, copied")
	end)

	t.test("season climate: the design's target table, from the real Temperature.target", function()
		-- { day, night, roof at night } for autumn, winter and spring; summer adds the roof by day
		-- and a heat wave. Rows: the seasons' design (bench/climate.luau).
		local TABLE = {
			Plains = { { -1, -3, -2 }, { -3, -9, -7 }, { 0, -2, -1 }, { 3, 1, 0, 1, 8 } },
			BirchForest = { { -2, -7, -4 }, { -7, -10, -10 }, { -2, -6, -3 }, { 1, -1, 0, 0, 4 } },
			Taiga = { { -6, -10, -8 }, { -10, -10, -10 }, { -5, -10, -7 }, { -1, -3, -2, 0, 1 } },
			Savanna = { { 3, 0, 0 }, { 1, -2, -1 }, { 4, 1, 0 }, { 8, 4, 2, 5, 10 } },
			Desert = { { 8, 3, 2 }, { 4, 1, 0 }, { 9, 4, 2 }, { 10, 9, 6, 10, 10 } },
		}
		local s = state()
		for name, rows in TABLE do
			local biome = assert(Biomes.byName(name))
			local class = SeasonClimate.classOf(biome.index)
			for season = 1, 4 do
				-- (Each season's middle: no blend.)
				local dayTime = ((season - 1) * 8 + 4) * DAY + 6000
				local sample = SeasonClimate.sample(dayTime, class, 1, s)
				local row = rows[season]
				local label = `{name} {Calendar.NAMES[season]}`
				t.eq(Temperature.target(env(biome.temperature, sample, false, true)), row[1], `{label} by day`)
				t.eq(Temperature.target(env(biome.temperature, sample, true, true)), row[2], `{label} at night`)
				t.eq(Temperature.target(env(biome.temperature, sample, true, false)), row[3], `{label} roof, night`)
				if season == Calendar.SUMMER then
					t.eq(Temperature.target(env(biome.temperature, sample, false, false)), row[4], `{label} roof, day`)
					local wave = table.clone(sample)
					wave.shift += Config.Seasons.Climate.HeatWave.Shift * SeasonClimate.amplitude(class)
					t.eq(Temperature.target(env(biome.temperature, wave, false, true)), row[5], `{label} heat wave`)
				end
			end
		end
		-- The continuous roof-night values the rooms lose to (§3): plains -6.7, taiga -14.2.
		local function roofNight(name: string): number
			local biome = assert(Biomes.byName(name))
			local sample = SeasonClimate.sample(12 * DAY, SeasonClimate.classOf(biome.index), 1, s)
			return Temperature.scaleOf(Temperature.climateValue(env(biome.temperature, sample, true, false)))
		end
		t.near(roofNight("Plains"), -6.67, 0.01)
		t.near(roofNight("Taiga"), -14.17, 0.01)
	end)

	t.test("season climate: heat waves are deterministic, summer only, never two in a row", function()
		local s = state()
		local seed = 12345
		local waves, summers, twice = 0, 0, false
		local before = false
		for day = 0, 32 * 60 - 1 do
			local wave = SeasonClimate.isHeatWave(day, seed, s)
			t.eq(SeasonClimate.isHeatWave(day, seed, s), wave, "the same answer twice")
			local season = Calendar.at(day + 0.5, s).season
			if season ~= Calendar.SUMMER then
				t.eq(wave, false, `day {day} is no summer day`)
			else
				summers += 1
			end
			if wave then
				waves += 1
				twice = twice or before
			end
			before = wave
		end
		t.eq(twice, false, "never two in a row")
		local share = waves / summers
		t.ok(share > 0.15 and share < 0.3, `{share * 100}% of summer days`)
		-- The bump: 0 before 09:00 and after 18:00, full in between.
		local day = nil
		for d = 24, 32 * 60 do
			if SeasonClimate.isHeatWave(d, seed, s) then
				day = d
				break
			end
		end
		assert(day, "a heat wave")
		t.eq(SeasonClimate.heatWave(day + 1000 / DAY, seed, s), 0, "early morning")
		t.eq(SeasonClimate.heatWave(day + 7000 / DAY, seed, s), 1, "afternoon")
		t.eq(SeasonClimate.heatWave(day + 15000 / DAY, seed, s), 0, "night")
		local sample = SeasonClimate.sample(day * DAY + 7000, "temperate", seed, s)
		t.eq(sample.heatWave, 1)
		local summer = Calendar.value(Config.Seasons.Climate.DayShift, day * DAY + 7000, s)
		t.near(sample.shift, summer + 0.3, 1e-9, "summer's shift and the wave's +0.30")
	end)

	t.test("season climate: snow caps by class and height, a drift of one, at most 8", function()
		local seed = 4242
		for x = -200, 200, 7 do
			for z = -200, 200, 11 do
				t.eq(SeasonClimate.snowCap("dry", x, 80, z, seed), 0, "no snow in dry biomes")
				local cold = SeasonClimate.snowCap("cold", x, 80, z, seed)
				t.ok(cold >= 5 and cold <= 7, `cold {cold}`)
				local temperate = SeasonClimate.snowCap("temperate", x, 80, z, seed)
				t.ok(temperate >= 2 and temperate <= 4, `temperate {temperate}`)
				local tropical = SeasonClimate.snowCap("tropical", x, 80, z, seed)
				t.ok(tropical >= 0 and tropical <= 2, `tropical {tropical}`)
				local high = SeasonClimate.snowCap("cold", x, 900, z, seed)
				t.ok(high >= 0 and high <= SeasonClimate.MAX_LAYERS, "at most 8")
			end
		end
		-- Higher up, more: +1 every 64 blocks above y 160.
		t.ok(SeasonClimate.snowCap("temperate", 0, 300, 0, seed) > SeasonClimate.snowCap("temperate", 0, 100, 0, seed))
		t.eq(SeasonClimate.snowCap("cold", 0, 2000, 0, seed), 8)
		t.eq(SeasonClimate.melts(0.1), false)
		t.eq(SeasonClimate.melts(0.19), false)
		t.eq(SeasonClimate.melts(0.2), true, "0.15 + 0.05")
	end)

	t.test("season climate: the far landscape's snow cover and growth through the year", function()
		local s = state()
		local function cover(time: number, class: string): number
			return SeasonClimate.snowCover(Calendar.at(time, s), class :: any)
		end
		t.eq(cover(4, "temperate"), 0, "mid autumn")
		t.eq(cover(8.5, "temperate") > 0 and cover(8.5, "temperate") < 1, true, "winter's first days")
		t.eq(cover(12, "temperate"), 1, "mid winter")
		t.eq(cover(17, "temperate") < 1 and cover(17, "temperate") > 0, true, "the thaw")
		t.eq(cover(20, "temperate"), 0, "mid spring")
		t.eq(cover(7.5, "cold") > 0, true, "the cold whiten before winter")
		t.eq(cover(17.5, "cold"), 1, "and stay white into spring")
		t.eq(cover(21, "cold"), 0)
		t.eq(cover(12, "dry"), 0)
		t.eq(cover(12, "tropical"), 0)
		t.eq(SeasonClimate.sample(12 * DAY, "temperate", 1, s).growth, 0, "winter: dormant")
		t.eq(SeasonClimate.sample(20 * DAY, "temperate", 1, s).growth, 1.5, "spring")
	end)

	t.test(
		"season climate: the season's snow thaws while the far cover goes or is gone, never while it holds or rises",
		function()
			local s = state()
			for _, class in SeasonClimate.CLASSES do
				for step = 0, 32 * 16 - 1 do
					local time = (step + 0.5) / 16
					local position = Calendar.at(time, s)
					local cover = SeasonClimate.snowCover(position, class :: any)
					local later = SeasonClimate.snowCover(Calendar.at(time + 1e-3, s), class :: any)
					t.eq(
						SeasonClimate.thawing(position, class :: any),
						cover < 1 and later <= cover,
						`{class} at {time}`
					)
				end
			end
			-- A taiga's spring: white over its first two days, thawing from the third, bare by the fifth.
			t.eq(SeasonClimate.thawing(Calendar.at(17.5, s), "cold"), false)
			t.eq(SeasonClimate.thawing(Calendar.at(18.5, s), "cold"), true)
			t.eq(SeasonClimate.thawing(Calendar.at(4, s), "cold"), true, "early autumn: bare")
			t.eq(SeasonClimate.thawing(Calendar.at(7, s), "cold"), false, "autumn's last days: whitening")
			t.eq(SeasonClimate.thawing(Calendar.at(4, s), "temperate"), true)
			t.eq(SeasonClimate.thawing(Calendar.at(8.5, s), "temperate"), false, "winter")
			t.eq(SeasonClimate.thawing(Calendar.at(12, s), "dry"), true)
		end
	)

	t.test("season climate: off, the identity (no shift, the old night, no biases)", function()
		local off = state()
		off.enabled = false
		t.eq(SeasonClimate.active(off), false)
		local sample = SeasonClimate.sample(12 * DAY, "temperate", 1, off)
		t.eq(sample.shift, 0)
		t.eq(sample.nightDrop, Temperature.NIGHT)
		t.eq(sample.weatherShift, 0)
		t.eq(sample.wetBias, 0)
		t.eq(sample.thunderBias, 0)
		t.eq(sample.growth, 1)
		t.eq(sample.snowCover, 0)
		t.eq(sample.heatWave, 0)
		-- The module's state starts off, so a sample without a state is the identity too.
		t.eq(SeasonClimate.sample(12 * DAY, "temperate", 1).shift, 0)
	end)
end
