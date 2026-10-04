--[[
	The day cycle: Minecraft's time maths (Shared/DayCycle: celestial angle, ClockTime, sky darkness
	and brightness, the sunrise glow, time arguments, the replicated clock, lighting blends) and the
	/time and /gamerule commands with their permissions (server Players/TimeCommand).
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local TimeCommand = require(server.Players.TimeCommand)

	--[[ Minecraft's maths ]]

	t.test("day cycle: celestial angle matches Minecraft's DimensionType.timeOfDay", function()
		t.near(DayCycle.timeOfDay(0), 0.78452, 1e-4, "sunrise")
		t.near(DayCycle.timeOfDay(6000), 0, 1e-9, "noon")
		t.near(DayCycle.timeOfDay(12000), 0.21548, 1e-4, "sunset")
		t.near(DayCycle.timeOfDay(18000), 0.5, 1e-9, "midnight")
		-- Later days repeat, and the angle only grows through a day (from noon on).
		t.near(DayCycle.timeOfDay(24000 * 3 + 6000), 0, 1e-9, "noon of day 3")
		local last = -1
		for tick = 6000, 6000 + 23999, 250 do
			local angle = DayCycle.timeOfDay(tick)
			t.ok(angle >= last, `angle grows at {tick}`)
			last = angle
		end
	end)

	t.test("day cycle: ClockTime puts the sun at Minecraft's angle", function()
		t.near(DayCycle.clockTime(6000), 12, 1e-6, "noon")
		t.near(DayCycle.clockTime(18000), 0, 1e-6, "midnight")
		-- Minecraft's sun is already 12 degrees up at tick 0 (the angle is not linear).
		t.near(DayCycle.clockTime(0), 6.83, 0.01, "tick 0")
		t.near(DayCycle.clockTime(12000), 17.17, 0.01, "tick 12000")
		-- The sun is on the horizon (6:00 and 18:00) a little before tick 0 and after 12000.
		t.ok(DayCycle.clockTime(23200) < 6 and DayCycle.clockTime(23300) > 6, "sunrise near tick 23215")
		t.ok(DayCycle.clockTime(12700) < 18 and DayCycle.clockTime(12850) > 18, "sunset near tick 12785")
		for tick = 0, 48000, 500 do
			local clock = DayCycle.clockTime(tick)
			t.ok(clock >= 0 and clock < 24, `clock in range at {tick}`)
		end
	end)

	t.test("day cycle: sky darkness is Minecraft's Level.getSkyDarken", function()
		t.eq(DayCycle.skyDarken(6000), 0, "noon")
		t.eq(DayCycle.skyDarken(18000), 11, "midnight")
		t.eq(DayCycle.skyDarken(1000), 0, "day")
		t.eq(DayCycle.skyDarken(13000), 6, "night (just after sunset)")
		-- The Minecraft wiki: the sky light is 4 from tick 13670 to 22330.
		t.eq(DayCycle.skyDarken(13660), 10)
		t.eq(DayCycle.skyDarken(13680), 11)
		t.eq(DayCycle.skyDarken(22320), 11)
		t.eq(DayCycle.skyDarken(22340), 10)
		t.eq(DayCycle.skyLight(18000), 4, "night sky light is 4")
		t.eq(DayCycle.skyLight(6000), 15)
		for tick = 0, 23999, 100 do
			local darken = DayCycle.skyDarken(tick)
			t.ok(darken >= 0 and darken <= 11 and darken == math.floor(darken), `whole 0..11 at {tick}`)
		end
		-- Darkness only rises from noon to midnight.
		local last = 0
		for tick = 6000, 18000, 100 do
			local darken = DayCycle.skyDarken(tick)
			t.ok(darken >= last, `rises at {tick}`)
			last = darken
		end
	end)

	t.test("day cycle: sky brightness and the sunrise glow", function()
		t.eq(DayCycle.skyBrightness(6000), 1, "noon")
		t.eq(DayCycle.skyBrightness(18000), 0, "midnight")
		t.eq(DayCycle.skyBrightness(1000), 1, "day")
		local dusk = DayCycle.skyBrightness(12500)
		t.ok(dusk > 0 and dusk < 1, `sunset is between ({dusk})`)
		t.eq(DayCycle.duskFactor(6000), 0, "no glow at noon")
		t.eq(DayCycle.duskFactor(18000), 0, "no glow at midnight")
		-- The glow peaks with the sun on the horizon (angle 0.25: cos = 0).
		local peak, peakTick = 0, 0
		for tick = 11000, 14000, 10 do
			local glow = DayCycle.duskFactor(tick)
			if glow > peak then
				peak, peakTick = glow, tick
			end
		end
		t.near(peak, 1, 1e-3, "peak")
		t.ok(peakTick > 12500 and peakTick < 13000, `peak at sunset ({peakTick})`)
		t.ok(DayCycle.duskFactor(23215) > 0.99, "and at sunrise")
	end)

	t.test("day cycle: days, time of day and clock strings", function()
		t.eq(DayCycle.day(0), 0)
		t.eq(DayCycle.day(23999), 0)
		t.eq(DayCycle.day(24000), 1)
		t.eq(DayCycle.day(100000), 4)
		t.eq(DayCycle.timeInDay(100000), 4000)
		t.eq(DayCycle.timeInDay(1234.9), 1234)
		t.eq(DayCycle.clockString(0), "06:00")
		t.eq(DayCycle.clockString(6000), "12:00")
		t.eq(DayCycle.clockString(18000), "00:00")
		t.eq(DayCycle.clockString(1500), "07:30")
		t.eq(DayCycle.clockString(24000 + 23999), "05:59")
	end)

	t.test("day cycle: the replicated clock", function()
		t.near(DayCycle.rate(), 24000 / Config.Time.DayLength, 1e-9)
		t.eq(DayCycle.now(1000, 50, 60, 20), 1200, "10 s at 20 ticks a second")
		t.eq(DayCycle.now(1000, 50, 500, 0), 1000, "stopped")
		t.eq(DayCycle.now(1000, 50, 49.9, 20), 1000, "never runs backwards")
	end)

	t.test("day cycle: time arguments like Minecraft's TimeArgument", function()
		local function ticks(text: string): number?
			return (DayCycle.parseTime(text))
		end
		t.eq(ticks("day"), 1000)
		t.eq(ticks("Noon"), 6000)
		t.eq(ticks("night"), 13000)
		t.eq(ticks("midnight"), 18000)
		t.eq(ticks("0"), 0)
		t.eq(ticks("1000"), 1000)
		t.eq(ticks("100t"), 100)
		t.eq(ticks("30s"), 600)
		t.eq(ticks("1d"), 24000)
		t.eq(ticks("0.5d"), 12000)
		t.eq(ticks("1.5s"), 30)
		t.eq(ticks("0.01s"), 0, "rounded")
		t.eq(ticks("0.03s"), 1, "rounded up")
		t.eq(ticks("1e9d"), nil, "not a number with a unit")
		t.eq(ticks("99999999d"), DayCycle.MAX_TICKS, "capped at an int")
		for _, bad in { "", "abc", "1x", "-5", "-1d", "1.2.3", "d", "1 d" } do
			local value, problem = DayCycle.parseTime(bad)
			t.eq(value, nil, `'{bad}' is refused`)
			t.ok(type(problem) == "string" and #problem > 0, `'{bad}' says why`)
		end
		local _, negative = DayCycle.parseTime("-5")
		t.eq(negative, "The tick count must not be less than 0, found -5")
		-- Names are /time set's only; durations do not know them.
		t.eq(DayCycle.parseDuration("day"), nil)
		t.eq(DayCycle.parseDuration("2d"), 48000)
	end)

	--[[ Lighting blends ]]

	t.test("day cycle: lighting follows the time and the depth", function()
		local light = Config.Lighting
		local function same(a: { number }, b: { number }, message: string)
			for i = 1, 3 do
				t.near(a[i], b[i], 1e-6, message)
			end
		end
		local noon = DayCycle.environment(6000, 1)
		same(noon.outdoorAmbient, light.Day.OutdoorAmbient, "noon outdoor ambient")
		same(noon.fogColor, light.Day.FogColor, "noon fog")
		t.near(noon.brightness, light.Day.Brightness, 1e-6, "noon brightness")
		t.near(noon.environmentDiffuse, light.Day.EnvironmentDiffuse, 1e-6)
		same(noon.ambient, light.CaveAmbient, "ambient is the cave light")

		local midnight = DayCycle.environment(18000, 1)
		same(midnight.outdoorAmbient, light.Night.OutdoorAmbient, "midnight outdoor ambient")
		same(midnight.colorShiftTop, light.Night.ColorShiftTop, "midnight colour shift")
		t.near(midnight.brightness, light.Night.Brightness, 1e-6, "midnight brightness")
		same(midnight.ambient, light.CaveAmbient, "same cave light at night")

		-- Sunset is warmer (more red than blue) than the plain day / night blend.
		local sunset = DayCycle.environment(12785, 1)
		t.ok(sunset.fogColor[1] > sunset.fogColor[3], "warm fog at sunset")
		t.ok(sunset.colorShiftTop[1] > sunset.colorShiftTop[3], "warm light at sunset")

		-- Deep underground only the cave light is left, day or night.
		for _, tick in { 6000, 12785, 18000 } do
			local cave = DayCycle.environment(tick, 0)
			same(cave.outdoorAmbient, { 0, 0, 0 }, "no sky light in caves")
			t.eq(cave.brightness, 0, "no sun in caves")
			t.eq(cave.environmentDiffuse, 0)
			t.eq(cave.environmentSpecular, 0)
			same(cave.ambient, light.CaveAmbient, "cave light")
			same(cave.fogColor, light.Underground.FogColor, "cave fog")
		end
		local half = DayCycle.environment(6000, 0.5)
		t.near(half.brightness, light.Day.Brightness / 2, 1e-6, "half way down")
	end)

	t.test("day cycle: the blend follows a sun height (the sun Roblox draws)", function()
		t.near(DayCycle.sunHeight(6000), 1, 1e-9, "noon: overhead")
		t.near(DayCycle.sunHeight(18000), -1, 1e-9, "midnight: underfoot")
		t.near(DayCycle.sunHeight(0), math.sin(math.rad(12.4)), 0.01, "tick 0: about 12 degrees up")
		t.ok(DayCycle.sunHeight(12700) > 0 and DayCycle.sunHeight(12850) < 0, "sets near tick 12785")
		-- skyBrightness / duskFactor are daylight / glow of Minecraft's sun.
		for tick = 0, 23999, 250 do
			local height = DayCycle.sunHeight(tick)
			t.eq(DayCycle.skyBrightness(tick), DayCycle.daylight(height), `daylight at {tick}`)
			t.eq(DayCycle.duskFactor(tick), DayCycle.glow(height), `glow at {tick}`)
		end
		t.eq(DayCycle.daylight(0.4), 1, "full day from about 24 degrees up")
		t.eq(DayCycle.daylight(-0.1), 0, "night from about 6 degrees down")
		t.eq(DayCycle.glow(0.5), 0)
		t.eq(DayCycle.glow(-0.5), 0)
		t.near(DayCycle.glow(0), 1, 1e-9, "glow peaks on the horizon")

		local function same(a: { number }, b: { number }, message: string)
			for i = 1, 3 do
				t.near(a[i], b[i], 1e-6, message)
			end
		end
		local light = Config.Lighting
		-- Without a height the blend is Minecraft's; with Minecraft's own height nothing changes.
		for _, tick in { 0, 6000, 12500, 12785, 18000, 23215 } do
			local plain = DayCycle.environment(tick, 1)
			local given = DayCycle.environment(tick, 1, nil, DayCycle.sunHeight(tick))
			same(plain.outdoorAmbient, given.outdoorAmbient, `same outdoor ambient at {tick}`)
			same(plain.fogColor, given.fogColor, `same fog at {tick}`)
			t.near(plain.brightness, given.brightness, 1e-9, `same brightness at {tick}`)
		end
		-- The height wins over the tick: a sun still high at Minecraft's dusk keeps the day.
		local high = DayCycle.environment(13000, 1, nil, 0.8)
		same(high.outdoorAmbient, light.Day.OutdoorAmbient, "sun up: day light")
		t.near(high.brightness, light.Day.Brightness, 1e-9)
		local low = DayCycle.environment(6000, 1, nil, -0.8)
		same(low.outdoorAmbient, light.Night.OutdoorAmbient, "sun down: night light")
		t.near(low.brightness, light.Night.Brightness, 1e-9)
		-- Out of range heights are clamped, and underground still wins.
		t.near(DayCycle.environment(6000, 1, nil, 3).brightness, light.Day.Brightness, 1e-9, "clamped")
		t.eq(DayCycle.environment(6000, 0, nil, 1).brightness, 0, "no sun in caves")
	end)

	t.test("day cycle: the underground fade settles", function()
		t.eq(DayCycle.approach(nil, 0.3, 0.1, 0.75), 0.3, "first value: the target at once")
		t.eq(DayCycle.approach(1, 0, 0.1, 0), 0, "no smoothing")
		local step = DayCycle.approach(1, 0, 0.1, 0.75)
		t.ok(step < 1 and step > 0.8, `one step moves a little ({step})`)
		t.eq(DayCycle.approach(0.5, 1, -1, 0.75), 0.5, "no time, no change")
		t.eq(DayCycle.approach(0.9995, 1, 0.1, 0.75), 1, "lands on the target when close")
		-- At 10 Hz it gets about 95% of the way in 3 time constants and then stops changing.
		local value: number? = 0
		local after: { number } = {}
		for i = 1, 100 do
			value = DayCycle.approach(value, 1, 0.1, 0.75)
			after[i] = value :: number
			t.ok((value :: number) <= 1, `never overshoots ({i})`)
		end
		t.ok(after[23] > 0.94 and after[23] < 0.97, `about 95% after 2.3 s ({after[23]})`)
		t.eq(after[60], 1, "settled exactly within 6 s")
		t.eq(after[100], 1)
	end)

	t.test("day cycle: sky exposure fades with depth", function()
		t.eq(DayCycle.skyExposure(-10, 4, 16), 1, "above ground")
		t.eq(DayCycle.skyExposure(4, 4, 16), 1, "at the start")
		t.eq(DayCycle.skyExposure(16, 4, 16), 0, "at the end")
		t.eq(DayCycle.skyExposure(100, 4, 16), 0, "deep")
		t.near(DayCycle.skyExposure(10, 4, 16), 0.5, 1e-9, "half way")
		local last = 1
		for depth = 0, 20, 0.5 do
			local value = DayCycle.skyExposure(depth, 4, 16)
			t.ok(value <= last, `falls at {depth}`)
			last = value
		end
		t.eq(DayCycle.skyExposure(3, 5, 5), 1, "no fade band")
		t.eq(DayCycle.skyExposure(5, 5, 5), 0)
	end)

	--[[ /time and /gamerule ]]

	local function context(mayUse: boolean, dayTime: number?, cycle: boolean?)
		return { mayUse = mayUse, dayTime = dayTime or 1000, gameTime = 4321.7, cycle = cycle ~= false }
	end

	t.test("time command: matching and permissions", function()
		t.ok(TimeCommand.matches("/time set day"))
		t.ok(TimeCommand.matches("/TIME"))
		t.ok(TimeCommand.matches("  /gamerule doDaylightCycle"))
		t.ok(not TimeCommand.matches("/timer"))
		t.ok(not TimeCommand.matches("what /time is it"))
		t.ok(not TimeCommand.matches(""))
		t.eq(TimeCommand.run("hello", context(true)), nil, "ordinary chat")
		t.eq(TimeCommand.run("/gamemode c", context(true)), nil, "another command")

		-- Admins, the owner and Studio, like changing other players' game modes.
		t.ok(TimeCommand.mayUse(5, { 5 }, false, false), "admin")
		t.ok(not TimeCommand.mayUse(5, { 4 }, false, false), "not an admin")
		t.ok(TimeCommand.mayUse(5, {}, true, false), "owner")
		t.ok(TimeCommand.mayUse(5, {}, false, true), "Studio")
	end)

	t.test("time command: set, add and query with Minecraft's answers", function()
		local result = TimeCommand.run("/time set day", context(true, 30000))
		t.eq(result.dayTime, 1000)
		t.eq(result.feedback[1], "Set the time to 1000")
		t.eq(TimeCommand.run("/time set midnight", context(true)).dayTime, 18000)
		t.eq(TimeCommand.run("/time set 0.5d", context(true)).dayTime, 12000)
		t.eq(TimeCommand.run("/Time Set NOON", context(true)).dayTime, 6000, "any case")
		result = TimeCommand.run("/time set 30000", context(true))
		t.eq(result.dayTime, 30000, "the day count is replaced (Minecraft 1.20)")
		t.eq(result.feedback[1], "Set the time to 30000")

		-- /time add answers with the new time of day, and keeps counting days.
		result = TimeCommand.run("/time add 1d", context(true, 25000.6))
		t.eq(result.dayTime, 49000)
		t.eq(result.feedback[1], "Set the time to 1000")
		result = TimeCommand.run("/time add 30s", context(true, 1000))
		t.eq(result.dayTime, 1600)
		t.eq(result.feedback[1], "Set the time to 1600")
		t.eq(TimeCommand.run("/time add day", context(true)).dayTime, nil, "no names for add")

		result = TimeCommand.run("/time query daytime", context(false, 3 * 24000 + 4567.8))
		t.eq(result.dayTime, nil, "queries change nothing")
		t.eq(result.feedback[1], "The time is 4567")
		t.eq(TimeCommand.run("/time query day", context(false, 3 * 24000 + 4567.8)).feedback[1], "The time is 3")
		t.eq(TimeCommand.run("/time query gametime", context(false)).feedback[1], "The time is 4321")
	end)

	t.test("time command: refusals and usage", function()
		local function says(text: string, ctx): string
			local result = TimeCommand.run(text, ctx)
			t.eq(result.dayTime, nil, text)
			t.eq(result.cycle, nil, text)
			t.eq(#result.feedback, 1, text)
			return result.feedback[1]
		end
		t.eq(says("/time set day", context(false)), TimeCommand.DENIED)
		t.eq(says("/time add 100", context(false)), TimeCommand.DENIED)
		t.eq(says("/time", context(true)), TimeCommand.USAGE)
		t.eq(says("/time rewind 5", context(true)), TimeCommand.USAGE)
		t.eq(says("/time set", context(true)), TimeCommand.SET_USAGE)
		t.eq(says("/time set day now", context(true)), TimeCommand.SET_USAGE)
		t.eq(says("/time add", context(true)), TimeCommand.ADD_USAGE)
		t.eq(says("/time query", context(true)), TimeCommand.QUERY_USAGE)
		t.eq(says("/time query weather", context(true)), TimeCommand.QUERY_USAGE)
		t.ok(string.find(says("/time set -100", context(true)), "must not be less than 0", 1, true))
		t.ok(string.find(says("/time set 5x", context(true)), "Invalid unit", 1, true))
		t.ok(string.find(says("/time add soon", context(true)), TimeCommand.ADD_USAGE, 1, true))
	end)

	t.test("gamerule: doDaylightCycle", function()
		local result = TimeCommand.run("/gamerule doDaylightCycle false", context(true))
		t.eq(result.cycle, false)
		t.eq(result.feedback[1], "Gamerule doDaylightCycle is now set to: false")
		result = TimeCommand.run("/gamerule dodaylightcycle TRUE", context(true, 1000, false))
		t.eq(result.cycle, true, "any case")
		t.eq(result.feedback[1], "Gamerule doDaylightCycle is now set to: true")

		result = TimeCommand.run("/gamerule doDaylightCycle", context(false, 1000, false))
		t.eq(result.cycle, nil, "a query")
		t.eq(result.feedback[1], "Gamerule doDaylightCycle is currently set to: false")

		result = TimeCommand.run("/gamerule doDaylightCycle false", context(false))
		t.eq(result.cycle, nil)
		t.eq(result.feedback[1], TimeCommand.DENIED_RULES)
		result = TimeCommand.run("/gamerule doDaylightCycle maybe", context(true))
		t.eq(result.cycle, nil)
		t.eq(result.feedback[1], "Invalid boolean, expected 'true' or 'false' but found 'maybe'")
		result = TimeCommand.run("/gamerule keepInventory true", context(true))
		t.eq(result.cycle, nil)
		t.ok(string.find(result.feedback[1], "Unknown game rule 'keepInventory'", 1, true))
		t.eq(TimeCommand.run("/gamerule", context(true)).feedback[1], TimeCommand.GAMERULE_USAGE)
		t.eq(TimeCommand.run("/gamerule a b c", context(true)).feedback[1], TimeCommand.GAMERULE_USAGE)
	end)
end
