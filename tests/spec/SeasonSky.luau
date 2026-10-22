--[[
	The seasons' mood in the sky (client Rendering/SeasonSky, pure parts): neutral with the
	calendar off (nothing in the light or the grading changes); a cool winter (blue in the sun's
	colour shift, +0.05 brightness, less saturation) and a warm autumn; continuous across every
	turn (Calendar's blend: no step anywhere in the year); only as far as the sky reaches the
	camera (none in a cave); a heat wave's washed-out warmth at the climate's own heat wave
	(SeasonClimate.heatWave, the held calendar's day too); the shifts kept within 0..255.
]]

return function(t, shared, require, _server, client)
	local Calendar = require(shared.Seasons.Calendar)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local SeasonSky = require(client.Rendering.SeasonSky)

	local DAY = 24000

	local function state(lock: number?): Calendar.State
		local s = Calendar.newState()
		s.enabled = true
		s.lock = lock
		return s
	end

	local function environment(): DayCycle.Environment
		return DayCycle.environment(4 * DAY + 6000, 1)
	end

	t.test("season sky: neutral with the calendar off, nothing changes", function()
		local off = Calendar.newState()
		off.enabled = false
		for day = 0, 31 do
			local mood = SeasonSky.mood(day * DAY + 6000, 1, off)
			t.ok(SeasonSky.isNeutral(mood), `day {day}: neutral`)
		end
		local plain = environment()
		local same = SeasonSky.apply(environment(), SeasonSky.mood(12 * DAY, 0, off), 1)
		for _, field in { "colorShiftTop", "outdoorAmbient", "ambient", "fogColor" } do
			for i = 1, 3 do
				t.eq((same :: any)[field][i], (plain :: any)[field][i], `{field}[{i}] unchanged`)
			end
		end
		t.eq(same.brightness, plain.brightness)
		local brightness, saturation, tint = SeasonSky.correction(SeasonSky.mood(12 * DAY, 0, off), 1)
		t.ok(brightness == 0 and saturation == 0, "no grading")
		t.ok(tint[1] == 255 and tint[2] == 255 and tint[3] == 255, "white")
		t.eq(SeasonSky.heatWave(26 * DAY + 6000, 7, off), 0, "no heat wave")
	end)

	t.test("season sky: a cool winter, a warm autumn", function()
		local s = state()
		local winter = SeasonSky.mood(12 * DAY + 6000, 0, s)
		local autumn = SeasonSky.mood(4 * DAY + 6000, 0, s)
		t.ok(winter.shift[3] > winter.shift[1], "winter's sun shifted blue")
		t.ok(autumn.shift[1] > autumn.shift[3], "autumn's warm")
		t.near(winter.brightness, 0.05, 1e-9, "winter: +0.05 brightness (the snow's glare)")
		t.ok(winter.saturation < 0 and autumn.saturation > 0, "winter greyer, autumn richer")
		t.ok(winter.tint[3] > winter.tint[1] and autumn.tint[1] > autumn.tint[3], "the tints")
		-- Mid season: exactly MOODS.
		for season, day in { 4, 12, 20, 28 } do
			local mood = SeasonSky.mood(day * DAY, 0, s)
			for i = 1, 3 do
				t.near(mood.shift[i], SeasonSky.MOODS.Shift[season][i], 1e-9, `season {season} shift[{i}]`)
				t.near(mood.tint[i], SeasonSky.MOODS.Tint[season][i], 1e-9, `season {season} tint[{i}]`)
			end
			t.near(mood.saturation, SeasonSky.MOODS.Saturation[season], 1e-9)
			t.ok(not SeasonSky.isNeutral(mood), `season {season} has a mood`)
		end
		-- Subtle: never more than a tenth of brightness, a fifth of saturation.
		for _, values in { SeasonSky.MOODS.Brightness, SeasonSky.MOODS.Saturation } do
			for _, value in values do
				t.ok(math.abs(value) <= 0.1, "subtle")
			end
		end
	end)

	t.test("season sky: no step anywhere in the year", function()
		local s = state()
		-- (30 seconds apart, at most the smoothstep's steepest: 1.5 x the seasons' difference over
		-- BlendDays; under a colour step for the shifts and tints, a hundredth for the grading.)
		local STEP = 600
		local slope = 1.5 * STEP / (Config.Seasons.BlendDays * DAY) * 1.01
		local function most(values: { number }): number
			local largest = 0
			for i = 1, 4 do
				largest = math.max(largest, math.abs(values[i] - values[i % 4 + 1]))
			end
			return largest
		end
		local function channel(colours: { { number } }, i: number): { number }
			return { colours[1][i], colours[2][i], colours[3][i], colours[4][i] }
		end
		local last = SeasonSky.mood(0, 0, s)
		local copy = SeasonSky.neutral()
		for ticks = STEP, 32 * DAY, STEP do
			local mood = SeasonSky.mood(ticks, 0, s, copy)
			for i = 1, 3 do
				local shiftStep = most(channel(SeasonSky.MOODS.Shift, i)) * slope
				local tintStep = most(channel(SeasonSky.MOODS.Tint, i)) * slope
				t.ok(shiftStep < 1 and tintStep < 1, "under a colour step")
				t.ok(math.abs(mood.shift[i] - last.shift[i]) <= shiftStep, `shift[{i}] at {ticks}`)
				t.ok(math.abs(mood.tint[i] - last.tint[i]) <= tintStep, `tint[{i}] at {ticks}`)
			end
			t.ok(math.abs(mood.brightness - last.brightness) <= most(SeasonSky.MOODS.Brightness) * slope)
			t.ok(math.abs(mood.saturation - last.saturation) <= most(SeasonSky.MOODS.Saturation) * slope)
			t.ok(most(SeasonSky.MOODS.Saturation) * slope < 0.01, "a hundredth")
			last = SeasonSky.mood(ticks, 0, s)
		end
		-- Halfway at a turn (the old season's last day and the new one's first).
		local turn = SeasonSky.mood(8 * DAY, 0, s)
		t.near(turn.brightness, 0.025, 1e-9, "halfway into winter's glare at the turn")
	end)

	t.test("season sky: only as far as the sky reaches, within 0..255", function()
		local s = state()
		local winter = SeasonSky.mood(12 * DAY + 6000, 0, s)
		local plain = environment()
		local cave = SeasonSky.apply(environment(), winter, 0)
		for i = 1, 3 do
			t.eq(cave.colorShiftTop[i], plain.colorShiftTop[i], "a cave: no shift")
		end
		local outdoors = SeasonSky.apply(environment(), winter, 1)
		for i = 1, 3 do
			t.near(outdoors.colorShiftTop[i], math.clamp(plain.colorShiftTop[i] + winter.shift[i], 0, 255), 1e-9)
			t.near(outdoors.outdoorAmbient[i], math.clamp(plain.outdoorAmbient[i] + winter.ambient[i], 0, 255), 1e-9)
		end
		local half = SeasonSky.apply(environment(), winter, 0.5)
		t.near(
			half.colorShiftTop[3],
			plain.colorShiftTop[3] + winter.shift[3] / 2,
			1e-9,
			"half the sky, half the shift"
		)
		local brightness, saturation, tint = SeasonSky.correction(winter, 0)
		t.ok(brightness == 0 and saturation == 0 and tint[3] == 255, "no grading underground")
		brightness = SeasonSky.correction(winter, 1)
		t.near(brightness, 0.05, 1e-9)
		-- Clamped: a bright dusk's shift never passes 255.
		local hot = SeasonSky.neutral()
		hot.shift = { 300, 300, 300 }
		local clamped = SeasonSky.apply(environment(), hot, 1)
		for i = 1, 3 do
			t.eq(clamped.colorShiftTop[i], 255)
		end
		-- The other fields are the blood moon's and the weather's: untouched.
		t.eq(outdoors.fogColor[1], plain.fogColor[1])
		t.eq(outdoors.ambient[1], plain.ambient[1])
	end)

	t.test("season sky: a heat wave's warmth, at the climate's heat wave", function()
		local s = state()
		-- A seed with a heat wave in the first summer.
		local seed, day = 0, -1
		for candidate = 1, 200 do
			for d = 24, 31 do
				if SeasonClimate.isHeatWave(d, candidate, s) then
					seed, day = candidate, d
					break
				end
			end
			if day >= 0 then
				break
			end
		end
		t.ok(day >= 0, "a seed with a heat wave")
		for ticks = 0, DAY - 1, 500 do
			local dayTime = day * DAY + ticks
			local sample = SeasonClimate.sample(dayTime, "temperate", seed, s)
			t.near(SeasonSky.heatWave(dayTime, seed, s), sample.heatWave, 1e-12, `the climate's at {ticks}`)
		end
		local noon = day * DAY + 7000
		local wave = SeasonSky.heatWave(noon, seed, s)
		t.ok(wave > 0.99, "full in the afternoon")
		local calm, hot = SeasonSky.mood(noon, 0, s), SeasonSky.mood(noon, wave, s)
		t.ok(hot.brightness > calm.brightness, "glare")
		t.ok(hot.saturation < calm.saturation, "washed out")
		t.ok(hot.tint[3] < calm.tint[3], "warmer")
		-- Held on that day: the wave comes every day, as the climate's.
		t.ok(SeasonSky.heatWave(100 * DAY + 7000, seed, state(day)) > 0.99, "held")
	end)
end
