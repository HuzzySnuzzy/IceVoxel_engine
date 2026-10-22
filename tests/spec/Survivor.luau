--[[
	The zombie apocalypse's survivor record and blood moon on both sides: the record's rules
	(server Apocalypse/SurvivalRules: a tick alive, zombie kills, a saved record clamped, the blood
	moons lived through from rise to set, Bleeding's level going up to its cap, sprinting by speed),
	the Survivor message, the day counter's words (never "tonight" once the moon has set) and
	widths, the blood moon's toasts (client Ui/SurvivorLine: as wide as their texts; "You survived
	the Blood Moon" only when the server counted it: a character that died under the moon hears
	nothing), no moons counted with the apocalypse off, and the red sky (client
	Rendering/BloodMoonSky: no tint by day, the full tint at midnight of a blood moon's night, the
	grading and the moon's size).
]]

return function(t, shared, require, server, client)
	local BloodMoon = require(shared.Apocalypse.BloodMoon)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local Protocol = require(shared.Net.Protocol)
	local SurvivalRules = require(server.Apocalypse.SurvivalRules)
	local SurvivorLine = require(client.Ui.SurvivorLine)
	local BloodMoonSky = require(client.Rendering.BloodMoonSky)

	local DAY = DayCycle.TICKS_PER_DAY
	local moon = Config.Apocalypse.BloodMoon
	-- Day 2 (0-based) is the first blood moon's (First = Every = 3).
	local BLOOD_DAY = 2
	local function at(day: number, time: number): number
		return day * DAY + time
	end

	t.test("survivor: a tick alive, zombie kills, a saved record clamped", function()
		local record = SurvivalRules.new()
		for _ = 1, 100 do
			SurvivalRules.tickAlive(record)
		end
		t.eq(record.alive, 100)
		t.ok(SurvivalRules.killed(record, "ZombieBrute"), "a brute counts")
		t.ok(SurvivalRules.killed(record, "Zombie"))
		t.ok(not SurvivalRules.killed(record, "Cow"), "a cow doesn't")
		t.ok(not SurvivalRules.killed(record, "nothing"))
		t.eq(record.kills, 2)
		local saved = SurvivalRules.fromSaved({ alive = 2 ^ 40, kills = 1e9, moons = -5, infection = 0 })
		t.eq(saved.alive, SurvivalRules.MAX_ALIVE)
		t.eq(saved.kills, 65535)
		t.eq(saved.moons, 0)
		local nan = SurvivalRules.fromSaved({ alive = 0 / 0, kills = 3.7, moons = 2, infection = 0 })
		t.eq(nan.alive, 0)
		t.eq(nan.kills, 3)
		t.eq(SurvivalRules.fromSaved(nil).alive, 0, "nothing saved: a fresh record")
		-- The Survivor message carries it.
		local payload = Protocol.encodeSurvivor(record.alive, record.kills, record.moons)
		t.eq(buffer.len(payload), 8)
		local back = Protocol.decodeSurvivor(payload) :: Protocol.Survivor
		t.eq(back.alive, 100)
		t.eq(back.kills, 2)
	end)

	-- Ticks `record` through day times from `from` to `to` (step 20); how many moons it counted.
	local function watch(record: SurvivalRules.Record, from: number, to: number): number
		local survived = 0
		for time = from, to, 20 do
			if SurvivalRules.moonTick(record, time, moon) then
				survived += 1
			end
		end
		return survived
	end

	t.test("survivor: a blood moon lived through from its rise to its set counts once", function()
		t.ok(BloodMoon.isBloodDay(BLOOD_DAY, moon))
		local through = SurvivalRules.new()
		t.eq(watch(through, at(BLOOD_DAY, 6000), at(BLOOD_DAY + 1, 1000)), 1, "rise to set")
		t.eq(through.moons, 1)
		-- Only from its rise: a character that came during it doesn't count it.
		local late = SurvivalRules.new()
		t.eq(watch(late, at(BLOOD_DAY, 18000), at(BLOOD_DAY + 1, 1000)), 0, "born under the moon")
		-- A /time set back to the morning forgets it; one past its End counts it.
		local back = SurvivalRules.new()
		watch(back, at(BLOOD_DAY, 12000), at(BLOOD_DAY, 15000))
		t.ok(not SurvivalRules.moonTick(back, at(BLOOD_DAY, 1000), moon), "back to the morning")
		t.eq(watch(back, at(BLOOD_DAY, 1020), at(BLOOD_DAY, 6000)), 0)
		t.eq(back.moons, 0)
		local forward = SurvivalRules.new()
		watch(forward, at(BLOOD_DAY, 12000), at(BLOOD_DAY, 15000))
		t.ok(SurvivalRules.moonTick(forward, at(BLOOD_DAY, 23900), moon), "past its End: survived")
		-- Two moons, two counts.
		local long = SurvivalRules.new()
		t.eq(watch(long, at(0, 0), at(6, 0)), 2, "days 2 and 5")
	end)

	t.test("survivor: a living tick counts alive always, blood moons only with the apocalypse on", function()
		local function night(apocalypse: boolean): SurvivalRules.Record
			local record = SurvivalRules.new()
			for time = at(BLOOD_DAY, 6000), at(BLOOD_DAY + 1, 1000), 1 do
				SurvivalRules.tickLiving(record, time, apocalypse, moon)
			end
			return record
		end
		local on, off = night(true), night(false)
		t.eq(on.moons, 1, "on: the moon survived")
		t.eq(off.moons, 0, "off: no blood moon to survive")
		t.eq(off.alive, on.alive, "alive ticks count either way")
		t.eq(on.alive, DAY - 5000 + 1)
	end)

	t.test("survivor: Bleeding a level up when already bleeding, never past its cap", function()
		local s = Config.Apocalypse.Bleeding
		t.eq(s.Ticks, 400)
		t.eq(s.MaxAmplifier, 1)
		local ticks, level = SurvivalRules.bleeding(0, nil, s)
		t.eq(ticks, 400, "a first wound")
		t.eq(level, 0)
		ticks, level = SurvivalRules.bleeding(150, 0, s)
		t.eq(ticks, 400, "refreshed to at least Ticks")
		t.eq(level, 1, "a level up")
		ticks, level = SurvivalRules.bleeding(900, 1, s)
		t.eq(ticks, 900, "a longer one stays")
		t.eq(level, 1, "at the cap")
	end)

	t.test("survivor: sprinting by speed with no Tough As Nails reports", function()
		t.ok(SurvivalRules.measuredSprint(5.6, 0, 1), "a sprint")
		t.ok(not SurvivalRules.measuredSprint(4.3, 0, 1), "a walk")
		t.ok(not SurvivalRules.measuredSprint(300, 0, 1), "a teleport")
		t.ok(not SurvivalRules.measuredSprint(3, 4, 0), "no time")
	end)

	t.test("survivor: the day line's words", function()
		local text, notice = SurvivorLine.text(at(0, 6000), 0, true, moon)
		t.eq(text, "Day 1 · Survived 0 days")
		t.eq(notice, nil, "two days to the first blood moon")
		text, notice = SurvivorLine.text(at(1, 6000), DAY + 5, true, moon)
		t.eq(text, "Day 2 · Survived 1 day", "one day")
		t.eq(notice, "Blood Moon tomorrow")
		text, notice = SurvivorLine.text(at(BLOOD_DAY, 6000), 3 * DAY, true, moon)
		t.eq(text, "Day 3 · Survived 3 days")
		t.eq(notice, "Blood Moon tonight")
		t.eq(select(2, SurvivorLine.text(at(BLOOD_DAY, 18000), 0, true, moon)), "Blood Moon", "while it is up")
		t.eq(select(2, SurvivorLine.text(at(BLOOD_DAY, 23800), 0, true, moon)), nil, "after it set")
		t.eq((SurvivorLine.text(at(4, 100), 9 * DAY, false, moon)), "Day 5", "creative: the day alone")
		t.eq((SurvivorLine.text(at(4, 100), nil, true, moon)), "Day 5", "no record yet")
		t.eq(SurvivorLine.NOTICE_COLOUR[1], 200)
		-- "Tonight" only until it rises: never at its End, once it has set.
		local function word(time: number): string?
			return select(2, SurvivorLine.text(at(BLOOD_DAY, time), 0, true, moon))
		end
		t.eq(word(moon.Start), "Blood Moon tonight", "at its Start (not up yet)")
		t.eq(word(moon.Start + 1), "Blood Moon")
		t.eq(word(moon.End - 1), "Blood Moon")
		t.eq(word(moon.End), nil, "at its End: set, not tonight")
		t.eq(word(moon.End + 1), nil)
	end)

	t.test("survivor: the day line's widths on one row and wrapped, in steps of 8", function()
		local function measure(text: string): number
			return (utf8.len(text) :: number) * 8
		end
		local one, wrap = SurvivorLine.widths("Day 3 · Survived 2 days", "Blood Moon tonight", measure)
		t.eq(one, 360, "23 + 21 characters and the shadow")
		t.eq(wrap, 192, "the day's row is the wider")
		local plain, none = SurvivorLine.widths("Day 4 · Survived 3 days", nil, measure)
		t.eq(plain, 192)
		t.eq(none, nil, "no notice: nothing to wrap")
		local _, long = SurvivorLine.widths("Day 5", "Blood Moon tomorrow", measure)
		t.eq(long, 160, "the notice's row is the wider")
		-- The toasts: Minecraft's 160 at least, else the text and 8 a side.
		t.eq(SurvivorLine.toastWidth(measure("Hi")), 160)
		t.eq(SurvivorLine.toastWidth(measure(SurvivorLine.TOASTS.tonight)), 232)
		t.eq(SurvivorLine.toastWidth(measure(SurvivorLine.TOASTS.sets)), 240)
	end)

	t.test("survivor: the blood moon's toasts at dawn, its rise and its set; none for a clock jump", function()
		local function events(from: number, to: number): string
			return table.concat(SurvivorLine.events(from, to, moon), ",")
		end
		t.eq(events(at(BLOOD_DAY - 1, 23990), at(BLOOD_DAY, 10)), "tonight", "dawn of a blood moon's day")
		t.eq(events(at(0, 23990), at(1, 10)), "", "an ordinary dawn")
		t.eq(events(at(BLOOD_DAY, 12490), at(BLOOD_DAY, 12510)), "rises")
		t.eq(events(at(BLOOD_DAY, 23490), at(BLOOD_DAY, 23510)), "sets")
		t.eq(events(at(BLOOD_DAY, 6000), at(BLOOD_DAY, 18000)), "", "a /time set: nothing")
		t.eq(events(at(BLOOD_DAY, 18000), at(BLOOD_DAY, 6000)), "", "back in time: nothing")
		t.eq(#SurvivorLine.events(nil, at(BLOOD_DAY, 18000), moon), 0, "the first frame")
		t.eq(SurvivorLine.TOASTS.rises, "The Blood Moon rises")
		t.eq(SurvivorLine.TOASTS.sets, "You survived the Blood Moon")
		t.eq(SurvivorLine.TOASTS.tonight, "A Blood Moon rises tonight")
	end)

	t.test("survivor (seasons): a winter moon counts and toasts by the sun's night", function()
		local Calendar = require(shared.Seasons.Calendar)
		local before = Calendar.state()
		local s = Calendar.newState()
		s.enabled = true
		Calendar.setState(s)
		local ok, err = pcall(function()
			-- Night 15 (day 14) is mid winter: its moon sets after the clock's midnight.
			local day = 14
			t.ok(BloodMoon.isBloodDay(day, moon))
			local record = SurvivalRules.new()
			t.eq(watch(record, at(day, 6000), at(day + 1, 3000)), 1, "rise to set, past midnight")
			local function events(from: number, to: number): string
				return table.concat(SurvivorLine.events(from, to, moon), ",")
			end
			local rise, set = nil, nil
			local up = false
			for tick = at(day, 6000), at(day + 1, 6000), 10 do
				local active = BloodMoon.active(tick, moon)
				if active and not up then
					rise = tick
				elseif up and not active then
					set = tick
				end
				up = active
			end
			assert(rise and set)
			t.ok(rise < at(day, moon.Start), "rises earlier than the clock's Start: the winter sun sets early")
			t.ok(set > at(day + 1, 0), "and sets after the clock's next day began")
			t.eq(events(rise - 10, rise), "rises")
			t.eq(events(set - 10, set), "sets")
			local text, notice = SurvivorLine.text(at(day + 1, 100), nil, true, moon)
			t.eq(text, `Day {day + 2}`, "the line's day is the clock's")
			t.eq(notice, "Blood Moon", "the moon is still up")
		end)
		Calendar.setState(before)
		if not ok then
			error(err, 0)
		end
	end)

	t.test("survivor: 'You survived the Blood Moon' needs the clock's set and the server's count", function()
		local seconds = SurvivorLine.CONFIRM_SECONDS
		local pending: SurvivorLine.Pending = {}
		t.ok(not SurvivorLine.confirmSet(pending, "sets", 100), "the set alone: waits")
		t.ok(SurvivorLine.confirmSet(pending, "raised", 100.3), "the count after it: due")
		t.eq(pending.sets, nil, "both forgotten")
		t.ok(not SurvivorLine.confirmSet(pending, "raised", 200), "the count first (the clock lags)")
		t.ok(SurvivorLine.confirmSet(pending, "sets", 200 + seconds), "then the set: due")
		-- A saved record coming back raises the count with no moon setting; a death under the
		-- moon leaves the set with no count.
		local restored: SurvivorLine.Pending = {}
		t.ok(not SurvivorLine.confirmSet(restored, "raised", 10))
		t.ok(not SurvivorLine.confirmSet(restored, "sets", 10 + seconds + 30), "too far apart")
		t.ok(SurvivorLine.confirmSet(restored, "raised", 10 + seconds + 31), "a fresh pair")

		-- The whole night, the server's record (SurvivalRules, reset by a death) beside the
		-- client's clock (SurvivorLine.events every 5 ticks: 0.25 s polls) and its toasts.
		local function night(diesAt: number?): number
			local record = SurvivalRules.new()
			local toasts = 0
			local waiting: SurvivorLine.Pending = {}
			local before: number? = nil
			local moons = 0
			local dead = false
			for time = at(BLOOD_DAY, 12000), at(BLOOD_DAY, 23800) do
				local now = (time - at(BLOOD_DAY, 12000)) / 20
				if diesAt and time == at(BLOOD_DAY, diesAt) then
					record = SurvivalRules.new()
					dead = true
				elseif dead and time == at(BLOOD_DAY, (diesAt :: number) + 200) then
					dead = false
				end
				if not dead then
					SurvivalRules.tickLiving(record, time, true, moon)
				end
				if record.moons > moons and SurvivorLine.confirmSet(waiting, "raised", now) then
					toasts += 1
				end
				moons = record.moons
				if time % 5 == 0 then
					for _, event in SurvivorLine.events(before, time, moon) do
						if event == "sets" and SurvivorLine.confirmSet(waiting, "sets", now) then
							toasts += 1
						end
					end
					before = time
				end
			end
			return toasts
		end
		t.eq(night(nil), 1, "lived through it: one toast")
		t.eq(night(18000), 0, "died under it and came back: none (the server counted none)")
	end)

	t.test("survivor: the blood moon's tint is 0 by day and 1 at midnight of a blood day", function()
		t.eq(BloodMoonSky.intensity(at(BLOOD_DAY, 6000)), 0, "noon")
		t.eq(BloodMoonSky.intensity(at(BLOOD_DAY, 18000)), 1, "midnight of a blood day")
		t.eq(BloodMoonSky.intensity(at(1, 18000)), 0, "midnight of an ordinary night")
		t.ok(BloodMoonSky.intensity(at(BLOOD_DAY, 12800)) < 1, "still rising")
		-- The light: unchanged at 0, TintStrength of the way to Tint at 1.
		local function environment(): DayCycle.Environment
			return DayCycle.environment(at(BLOOD_DAY, 18000), 1)
		end
		local plain = environment()
		local untouched = BloodMoonSky.apply(environment(), 0)
		t.eq(untouched.ambient[1], plain.ambient[1], "0: nothing changes")
		t.eq(untouched.fogColor[2], plain.fogColor[2])
		local red = BloodMoonSky.apply(environment(), 1)
		local share = moon.TintStrength
		for _, field in { "ambient", "outdoorAmbient", "colorShiftTop", "fogColor", "decay" } do
			local before, after = (plain :: any)[field], (red :: any)[field]
			for i = 1, 3 do
				local expected = before[i] + (moon.Tint[i] - before[i]) * share
				t.ok(math.abs(after[i] - expected) < 1e-9, `{field}[{i}] tinted by TintStrength`)
			end
		end
		t.ok(red.ambient[1] > red.ambient[3], "red over blue")
		-- The grading: white by day, toward Tint by intensity x exposure; nothing deep underground.
		local white = BloodMoonSky.tintColour(0, 1)
		t.eq(white[1] + white[2] + white[3], 765)
		local full = BloodMoonSky.tintColour(1, 1)
		t.ok(math.abs(full[2] - (255 + (moon.Tint[2] - 255) * share)) < 1e-9)
		local cave = BloodMoonSky.tintColour(1, 0)
		t.eq(cave[2], 255, "no sky, no tint")
		-- The moon: 1.6 x at full.
		t.eq(BloodMoonSky.moonSize(11, 0), 11)
		t.ok(math.abs(BloodMoonSky.moonSize(11, 1) - 11 * moon.MoonSize) < 1e-9)
	end)
end
