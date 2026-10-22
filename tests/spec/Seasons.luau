--[[
	The seasons' calendar (Shared/Seasons/Calendar): positions across years and before day 0, the
	lock (held at the exact time, so neither the sun nor anything blended moves when it is held or
	runs on at that time of day), the offset kept over /time set and moved by /season set, the
	smooth blends at the turns, the sun's warp (Shared/DayCycle.solarTime: monotonic, continuous at
	midnight, the identity with the seasons off or a share of 1, winter's and summer's day shares),
	saves (re-anchored when the lengths change: a season's first day stays its first, its last its
	last; version 1's whole held day still read back) and the attributes, a world without a "seasons"
	save starting at Autumn's first day, and a world played without seasons saving none. Then
	server World/SeasonClock itself, loaded with a fake day clock and workspace: holding moves
	nothing, a world without seasons keeps the section it had (or saves none), and a calendar that
	can't be read starts on Autumn's first day only once the day clock is back. The module's state
	is shared by every spec: each test puts it back.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- World/SeasonClock, loaded here with its Roblox globals as arguments (after the --! lines).
local CLOCK = "src/server/World/SeasonClock.luau"
local GLOBALS = "script, require, game, workspace, Instance, task"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

return function(t, shared, require)
	local Config = require(shared.Config)
	local Calendar = require(shared.Seasons.Calendar)
	local DayCycle = require(shared.DayCycle)

	local DAY = 24000

	local function state(lengths: { number }?, offset: number?, lock: number?): any
		local s = Calendar.newState()
		s.enabled = true
		s.offset = offset or 0
		s.lock = lock
		if lengths then
			s.lengths = lengths
		end
		return s
	end

	-- Runs `fn` with `s` as the module's state, then puts the old one back.
	local function with(s: any, fn: () -> ())
		local before = Calendar.state()
		Calendar.setState(s)
		local ok, err = pcall(fn)
		Calendar.setState(before)
		if not ok then
			error(err, 0)
		end
	end

	t.test("seasons: Config's defaults (8 days each, Autumn first, a 2 day blend)", function()
		t.eq(Config.Seasons.Enabled, true, "on")
		t.eq(#Config.Seasons.Lengths, 4)
		for i = 1, 4 do
			t.eq(Config.Seasons.Lengths[i], 8, `season {i} lasts 8 days`)
		end
		t.eq(Config.Seasons.BlendDays, 2)
		t.eq(Calendar.NAMES[Calendar.AUTUMN], "Autumn")
		t.eq(Calendar.NAMES[Calendar.WINTER], "Winter")
		t.eq(Calendar.NAMES[Calendar.SPRING], "Spring")
		t.eq(Calendar.NAMES[Calendar.SUMMER], "Summer")
		t.eq(Calendar.yearLength(state()), 32)
		-- (The module's own state starts disabled: everything is as without seasons until set.)
		t.eq(Calendar.state().enabled, false, "the module starts disabled")
	end)

	t.test("seasons: positions across years and before day 0", function()
		local s = state()
		local p = Calendar.position(1000, s)
		t.eq(p.calendarDay, 0)
		t.eq(p.year, 0)
		t.eq(p.season, Calendar.AUTUMN)
		t.eq(p.day, 0)
		t.eq(p.days, 8)
		t.eq(p.daysLeft, 8, "the first day counts")
		p = Calendar.position(7 * DAY + 100, s)
		t.eq(p.season, Calendar.AUTUMN)
		t.eq(p.day, 7)
		t.eq(p.daysLeft, 1, "the last day of autumn")
		-- The season turns at sunrise (tick 0) of its first day.
		t.eq(Calendar.position(8 * DAY - 1, s).season, Calendar.AUTUMN)
		t.eq(Calendar.position(8 * DAY, s).season, Calendar.WINTER)
		p = Calendar.position(10 * DAY + 6000, s)
		t.eq(p.season, Calendar.WINTER)
		t.eq(p.day, 2)
		t.eq(p.daysLeft, 6)
		t.near(p.progress, (2 + 0.25) / 8, 1e-12)
		t.near(p.yearProgress, (10 + 0.25) / 32, 1e-12)
		-- Year 1, and before day 0 (negative day times, or an offset back).
		p = Calendar.position((32 + 17) * DAY, s)
		t.eq(p.year, 1)
		t.eq(p.season, Calendar.SPRING)
		t.eq(p.day, 1)
		p = Calendar.position(-1, s)
		t.eq(p.calendarDay, -1)
		t.eq(p.year, -1)
		t.eq(p.season, Calendar.SUMMER)
		t.eq(p.day, 7)
		t.eq(p.daysLeft, 1)
		p = Calendar.position(DAY, state(nil, -9))
		t.eq(p.calendarDay, -8)
		t.eq(p.season, Calendar.SUMMER)
		t.eq(p.day, 0)
		-- Every day of three years and the one before: the seasons in order, 8 days each.
		local last = nil
		for day = -32, 95 do
			local q = Calendar.position(day * DAY + 12000, s)
			t.eq(q.calendarDay, day)
			t.eq(q.season, (day // 8) % 4 + 1, `season of day {day}`)
			t.eq(q.day, day % 8, `day in season of {day}`)
			t.eq(q.year, day // 32, `year of {day}`)
			if last then
				t.ok(q.time > last, "time grows")
			end
			last = q.time
		end
		-- Unequal lengths.
		local odd = state({ 3, 5, 2, 7 })
		t.eq(Calendar.position(2 * DAY, odd).season, Calendar.AUTUMN)
		t.eq(Calendar.position(3 * DAY, odd).season, Calendar.WINTER)
		t.eq(Calendar.position(8 * DAY, odd).season, Calendar.SPRING)
		t.eq(Calendar.position(10 * DAY, odd).season, Calendar.SUMMER)
		t.eq(Calendar.position(16 * DAY, odd).day, 6)
		t.eq(Calendar.position(17 * DAY, odd).year, 1)
	end)

	t.test("seasons: the lock stands the calendar still at its time (doSeasonCycle false)", function()
		local s = state(nil, 0, 12.4)
		for _, dayTime in { 0, 5000, 3 * DAY, 100 * DAY + 777 } do
			local p = Calendar.position(dayTime, s)
			t.eq(p.calendarDay, 12, "the held day")
			t.eq(p.time, 12.4, "its time: nothing blends while held")
			t.eq(p.season, Calendar.WINTER)
		end
		t.eq(Calendar.day(50 * DAY, s), 12)
	end)

	t.test("seasons: holding the calendar moves neither the sun nor anything it blends", function()
		local s = state()
		local values = { 10, 20, 30, 40 }
		-- The sun, a blended value and the sun's share at `dayTime` with `st`.
		local function look(st: any, dayTime: number): (number, number, number)
			local solar = 0
			with(st, function()
				solar = DayCycle.solarTime(dayTime)
			end)
			return solar, Calendar.value(values, dayTime, st), Calendar.daylightScale(dayTime, st)
		end
		-- Winter's first day at 11000: a blend day (the sun's share and every value move with it).
		local now = 8 * DAY + 11000
		local held = Calendar.hold(s, true, now)
		t.ok(held ~= s and s.lock == nil, "a new state")
		t.eq(Calendar.hold(held, true, now), held, "held already: the same")
		local solar, value, k = look(s, now)
		t.ok(k < 1 and value > 10 and value < 20, "a blend day")
		local heldSolar, heldValue, heldK = look(held, now)
		t.eq(heldSolar, solar, "the sun stays where it is")
		t.eq(heldValue, value, "every blended value too")
		t.eq(heldK, k)
		t.eq(Calendar.day(now, held), 8)
		-- Held, every day is that one: the same share and values.
		for day = 9, 40, 7 do
			local _, v, share = look(held, day * DAY + 3000)
			t.eq(v, value, `day {day}: the value held`)
			t.eq(share, k, `day {day}: the sun's share held`)
		end
		-- Running on at once: as before.
		local running = Calendar.hold(held, false, now)
		t.eq(running.lock, nil)
		t.eq(running.offset, s.offset, "on at once: the calendar it was")
		-- Days later at the held time of day: nothing moves either.
		local later = 50 * DAY + 11000
		running = Calendar.hold(held, false, later)
		local laterSolar, laterValue = look(running, later)
		local heldLaterSolar = look(held, later)
		t.near(laterSolar, heldLaterSolar, 1e-6, "the sun")
		t.near(laterValue, value, 1e-9, "the values")
		t.eq(Calendar.day(later, running), 8, "on from the held day")
		-- At another time of day on the same side of midnight: from the held day, the sun kept.
		local other = 50 * DAY + 3000
		running = Calendar.hold(held, false, other)
		local otherSolar = look(running, other)
		local heldOtherSolar = look(held, other)
		t.near(otherSolar, heldOtherSolar, 1e-6, "the sun keeps its share")
		t.eq(Calendar.day(other, running), 8)
		t.near(Calendar.time(other, running), 8 + 3000 / DAY, 1e-9, "at the time of day it is")
	end)

	t.test("seasons: /time set keeps the calendar, /season set moves only the offset", function()
		local s = state(nil, 3)
		local before = 5 * DAY + 4000
		t.eq(Calendar.day(before, s), 8)
		-- /time set 1000: the day count goes back to 0, the calendar stays on day 8.
		local after = 1000
		s.offset = Calendar.keep(before, after, s)
		t.eq(s.offset, 8)
		t.eq(Calendar.day(after, s), 8, "the same calendar day")
		-- /season set summer 3 (day 2, 0-based) at the time of day it is.
		local now = 40 * DAY + 9000
		local offset, day = Calendar.offsetFor(Calendar.SUMMER, 2, now, s)
		s.offset = offset
		local p = Calendar.position(now, s)
		t.eq(p.season, Calendar.SUMMER)
		t.eq(p.day, 2)
		t.eq(p.calendarDay, day)
		t.eq(p.year, 1, "within the year it was in")
		t.eq(DayCycle.timeInDay(now), 9000, "the time of day stays")
		-- A day beyond the season's length is its last.
		offset = Calendar.offsetFor(Calendar.WINTER, 99, now, s)
		s.offset = offset
		t.eq(Calendar.position(now, s).day, 7)
	end)

	t.test("seasons: quantities blend smoothly over 2 days at every turn", function()
		local s = state()
		local values = { 10, 20, 30, 40 }
		t.eq(Calendar.valueAt(values, 4, s), 10, "mid autumn")
		t.eq(Calendar.valueAt(values, 12, s), 20, "mid winter")
		t.near(Calendar.valueAt(values, 8, s), 15, 1e-9, "halfway at the turn")
		t.near(Calendar.valueAt(values, 0, s), 25, 1e-9, "summer to autumn at day 0")
		t.eq(Calendar.valueAt(values, 7, s), 10, "the blend starts a day before")
		t.eq(Calendar.valueAt(values, 9, s), 20, "and ends a day after")
		-- Continuous everywhere (fine steps), no jump at the turns.
		local worst = 0
		local last = Calendar.valueAt(values, -1, s)
		for i = 1, 34 * 400 do
			local time = -1 + i / 400
			local value = Calendar.valueAt(values, time, s)
			worst = math.max(worst, math.abs(value - last))
			last = value
		end
		-- (A smoothstep over 2 days of a step of 30, summer's 40 to autumn's 10, moves at most
		-- 22.5 a day: 0.056 per 1/400.)
		t.ok(worst < 0.06, `the largest step is {worst}`)
		for _, turn in { 0, 8, 16, 24, 32 } do
			local below = Calendar.valueAt(values, turn - 1e-9, s)
			local above = Calendar.valueAt(values, turn, s)
			t.ok(math.abs(above - below) <= 1e-6, `no jump at day {turn}`)
		end
		-- At the turns themselves, from both sides to 1e-9 of a day.
		for _, turn in { 8, 16, 24 } do
			t.near(Calendar.valueAt(values, turn - 1e-12, s), Calendar.valueAt(values, turn, s), 1e-9, `turn {turn}`)
		end
		-- By day time.
		t.near(Calendar.value(values, 8 * DAY, s), 15, 1e-9)
	end)

	t.test("seasons: the sun's warp is monotonic, continuous, fixed at noon and midnight", function()
		local s = state()
		local last = -math.huge
		local largest = 0
		for tick = -DAY, 40 * DAY, 13 do
			local solar = Calendar.solarTime(tick, s)
			t.ok(solar >= last, `never back at {tick}`)
			if last > -math.huge then
				largest = math.max(largest, solar - last)
			end
			last = solar
		end
		-- (13 ticks of real time are at most 13 / 0.6 of the sun's.)
		t.ok(largest <= 13 / 0.6 + 1e-6, `continuous: the largest step is {largest}`)
		for day = 0, 40 do
			t.near(Calendar.solarTime(day * DAY + 6000, s), day * DAY + 6000, 1e-6, `noon of day {day}`)
			t.near(Calendar.solarTime(day * DAY + 18000, s), day * DAY + 18000, 1e-6, `midnight of day {day}`)
			-- Midnight from both sides.
			local before = Calendar.solarTime(day * DAY + 18000 - 1e-6, s)
			local after = Calendar.solarTime(day * DAY + 18000 + 1e-6, s)
			t.ok(math.abs(after - before) < 1e-3, `no jump at midnight {day}`)
		end
		-- The identity: a share of 1 (mid autumn), and the seasons off.
		for tick = 3 * DAY, 4 * DAY, 97 do
			t.eq(Calendar.solarTime(tick, s), tick, "k = 1 in mid autumn")
		end
		local off = state()
		off.enabled = false
		for tick = 10 * DAY, 11 * DAY, 101 do
			t.eq(Calendar.solarTime(tick, off), tick, "off")
		end
		t.eq(Calendar.daylightScale(12 * DAY, off), 1)
		-- The shares: 1.0, 0.8, 1.0, 1.2 in each season's middle.
		t.near(Calendar.daylightScale(4 * DAY, s), 1.0, 1e-12)
		t.near(Calendar.daylightScale(12 * DAY, s), 0.8, 1e-12)
		t.near(Calendar.daylightScale(20 * DAY, s), 1.0, 1e-12)
		t.near(Calendar.daylightScale(28 * DAY, s), 1.2, 1e-12)
		-- A solar day's share is its noon's: the same for the whole day.
		t.eq(Calendar.daylightScale(8 * DAY - 5999, s), Calendar.daylightScale(8 * DAY + 17999, s))
	end)

	t.test("seasons: winter's day is 45 % of it, summer's 64 % (Minecraft's isDay share 54.5 %)", function()
		with(state(), function()
			local function share(day: number): number
				local up, n = 0, 0
				for tick = 0, DAY - 1, 8 do
					n += 1
					if DayCycle.isDay(day * DAY + tick) then
						up += 1
					end
				end
				return up / n
			end
			t.near(share(4), 0.545, 0.01, "autumn")
			t.near(share(12), 0.45, 0.01, "winter")
			t.near(share(20), 0.545, 0.01, "spring")
			t.near(share(28), 0.64, 0.01, "summer")
		end)
	end)

	t.test("seasons: a save keeps the calendar, re-anchored when the lengths change", function()
		local s = state(nil, 5)
		local dayTime = 30 * DAY + 1234
		local saved = assert(Calendar.encode(s, dayTime))
		t.eq(saved.v, Calendar.VERSION)
		t.eq(saved.offset, 5)
		t.eq(saved.day, 35)
		t.eq(saved.lock, nil)
		local back = assert(Calendar.decode(saved, state()))
		t.eq(back.offset, 5, "the same lengths: the same offset")
		t.eq(back.lock, nil)
		-- Through JSON-like data (tables of numbers): the lengths are a copy.
		saved.lengths[1] = 8
		-- Config's lengths changed (8 each to 4, 6, 10, 12): the season and progress are kept.
		local newLengths = { 4, 6, 10, 12 }
		local wider = assert(Calendar.decode(saved, state(newLengths)))
		local oldPosition = Calendar.position(dayTime, s)
		local newPosition = Calendar.position(dayTime, wider)
		t.eq(oldPosition.season, Calendar.AUTUMN, "day 35: year 1, autumn day 3")
		t.eq(newPosition.season, oldPosition.season, "the same season")
		t.eq(newPosition.year, oldPosition.year, "the same year")
		t.eq(newPosition.day, math.floor(3 * (4 - 1) / (8 - 1) + 0.5), "in proportion")
		-- A held time moves the same way, its time of day kept.
		local locked = state(nil, 0, 13.3)
		local lockedBack = assert(Calendar.decode(Calendar.encode(locked, 0), state(newLengths)))
		local lockedPosition = Calendar.position(0, lockedBack)
		t.eq(lockedPosition.season, Calendar.WINTER)
		t.near((lockedBack.lock :: number) % 1, 0.3, 1e-9)
		t.eq(assert(Calendar.decode(Calendar.encode(locked, 0), state())).lock, 13.3, "the same lengths: as held")
		-- It doesn't depend on the day time decoded before or after: only the saved day.
		t.eq(Calendar.decode(saved, state(newLengths)).offset, wider.offset)
		-- Version 1 (a whole held day, held at its middle) still reads, as it was held.
		local old =
			assert(Calendar.decode({ v = 1, offset = 0, lock = 13, lengths = { 8, 8, 8, 8 }, day = 13 }, state()))
		t.eq(old.lock, 13.5)
		t.eq(Calendar.position(77 * DAY, old).calendarDay, 13)
		t.eq(assert(Calendar.decode({ v = 1, offset = 4, lengths = { 8, 8, 8, 8 }, day = 9 }, state())).offset, 4)
		-- Malformed saves are refused.
		for _, bad in
			{
				1,
				"x",
				{},
				{ v = 2 },
				{ v = 3, offset = 0, day = 0, lengths = { 8, 8, 8, 8 } },
				{ v = 1, offset = 0.5, day = 0, lengths = { 8, 8, 8, 8 } },
				{ v = 1, offset = 0, day = 0, lock = 2.5, lengths = { 8, 8, 8, 8 } },
				{ v = 2, offset = 0, day = 0, lock = math.huge, lengths = { 8, 8, 8, 8 } },
			}
		do
			t.eq(Calendar.decode(bad, state()), nil)
		end
		t.eq(Calendar.decode({ v = 1, offset = 0, day = 0, lengths = { 8, 8, 0, 8 } }, state()), nil, "a 0 day season")
	end)

	t.test("seasons: re-anchored to other lengths, a season's first day stays its first, its last its last", function()
		-- (Winter's first day of 8 was the second of 16.)
		local dayTime = 8 * DAY + 6000
		local wider = assert(Calendar.decode(Calendar.encode(state(), dayTime), state({ 16, 16, 16, 16 })))
		t.eq(Calendar.position(dayTime, wider).season, Calendar.WINTER)
		t.eq(Calendar.position(dayTime, wider).day, 0, "the first day")
		for _, case in { { 8, 16 }, { 16, 8 }, { 8, 3 }, { 3, 8 }, { 1, 5 }, { 5, 1 } } do
			local from, to = case[1], case[2]
			local saved = state({ from, from, from, from }, 7)
			local new = state({ to, to, to, to })
			for season = 1, 4 do
				local last = -1
				for day = 0, from - 1 do
					-- (Year 1, so the year is kept too.)
					local at = (Calendar.yearLength(saved) + Calendar.seasonStart(season, saved) + day - 7) * DAY + 9000
					local p = Calendar.position(at, assert(Calendar.decode(Calendar.encode(saved, at), new)))
					local name = `{from} to {to}: season {season} day {day}`
					t.eq(p.season, season, name)
					t.eq(p.year, 1, name)
					t.ok(p.day >= last, `{name}: in order`)
					last = p.day
					if day == 0 then
						t.eq(p.day, 0, `{name}: the first`)
					end
					if day == from - 1 and from > 1 then
						t.eq(p.day, to - 1, `{name}: the last`)
					end
				end
			end
		end
	end)

	t.test("seasons: a world played without seasons saves none, so they start on Autumn's day 1", function()
		-- Played with the seasons off from day 0 to day 18, a hold set then too.
		local now = 18 * DAY + 5000
		local off = Calendar.fresh(0)
		off.enabled = false
		off = Calendar.hold(off, true, now)
		t.eq(Calendar.encode(off, now), nil, "no section: neither the days nor the hold")
		-- With them on, no section: Autumn's first day there (it was Spring's third).
		local on = Calendar.decode(Calendar.encode(off, now), state()) or Calendar.fresh(now)
		local p = Calendar.position(now, on)
		t.eq(p.season, Calendar.AUTUMN)
		t.eq(p.day, 0)
		t.eq(on.lock, nil, "running")
		-- A section saved while it had seasons stays as it was.
		local kept = Calendar.encode(state(nil, 5), 30 * DAY)
		t.eq(Calendar.encode(off, 40 * DAY, kept), kept, "kept unchanged")
		t.eq((kept :: any).offset, 5)
	end)

	t.test("seasons: attributes round trip (before the server says anything: off)", function()
		local attributes: { [string]: any } = {}
		local function set(name: string, value: any)
			attributes[name] = value
		end
		local function get(name: string): any
			return attributes[name]
		end
		local nothing = Calendar.readAttributes(get)
		t.eq(nothing.enabled, false, "nothing published: off")
		t.eq(nothing.offset, 0)
		local s = state({ 3, 4, 5, 6 }, -7, 11)
		Calendar.writeAttributes(s, set)
		t.eq(attributes[Calendar.ATTRIBUTE_LENGTHS], "3,4,5,6")
		local read = Calendar.readAttributes(get)
		t.eq(read.enabled, true)
		t.eq(read.offset, -7)
		t.eq(read.lock, 11)
		for i = 1, 4 do
			t.eq(read.lengths[i], s.lengths[i])
		end
		s.lock = nil
		Calendar.writeAttributes(s, set)
		t.eq(Calendar.readAttributes(get).lock, nil, "unlocked")
		attributes[Calendar.ATTRIBUTE_LENGTHS] = "1,2"
		attributes[Calendar.ATTRIBUTE_OFFSET] = 0.5
		read = Calendar.readAttributes(get)
		t.eq(read.offset, 0, "a broken offset")
		t.eq(read.lengths[1], Config.Seasons.Lengths[1], "broken lengths: Config's")
	end)

	t.test("seasons: a world saved without seasons (or a new one) starts at Autumn's day 1 now", function()
		for _, dayTime in { 1000, 5 * DAY + 300, 77 * DAY + 23999 } do
			local s = Calendar.fresh(dayTime)
			local p = Calendar.position(dayTime, s)
			t.eq(p.calendarDay, 0, "calendar day 0")
			t.eq(p.season, Calendar.AUTUMN)
			t.eq(p.day, 0)
			t.eq(p.daysLeft, 8, "8 days of grace before winter")
			t.eq(s.enabled, Config.Seasons.Enabled)
			t.eq(Calendar.position(dayTime + 8 * DAY, s).season, Calendar.WINTER)
		end
	end)

	t.test("seasons: off, the day and the blood moon are exactly as without them", function()
		local BloodMoon = require(shared.Apocalypse.BloodMoon)
		local settings = Config.Apocalypse.BloodMoon
		local off = state()
		off.enabled = false
		with(off, function()
			for tick = 0, 30 * DAY, 250 do
				t.eq(DayCycle.solarTime(tick), tick)
				t.eq(DayCycle.timeOfDay(tick), DayCycle.celestialAngle(tick))
				t.eq(DayCycle.solarDay(tick), DayCycle.day(tick))
				t.eq(DayCycle.solarTimeInDay(tick), DayCycle.timeInDay(tick))
			end
			-- The blood moon of night 3 (day 2) from 12500 to 23500 ticks into the day.
			t.eq(BloodMoon.active(2 * DAY + 12499, settings), false)
			t.ok(BloodMoon.active(2 * DAY + 12600, settings))
			t.ok(BloodMoon.active(2 * DAY + 23400, settings))
			t.eq(BloodMoon.active(2 * DAY + 23501, settings), false)
		end)
	end)

	t.test("seasons: the blood moon keeps its place by the seasonal sun (earlier in winter)", function()
		local BloodMoon = require(shared.Apocalypse.BloodMoon)
		local settings = Config.Apocalypse.BloodMoon
		with(state(), function()
			-- One blood moon in each season's middle (nights 6, 15, 21, 30: days 5, 14, 20, 29).
			local rises: { number } = {}
			local heights: { number } = {}
			for season, day in { 5, 14, 20, 29 } do
				t.ok(BloodMoon.isBloodDay(day, settings), `day {day} has one`)
				local rose, set = nil, nil
				local up = false
				for tick = day * DAY + 6000, (day + 1) * DAY + 6000, 5 do
					local active = BloodMoon.active(tick, settings)
					if active and not up then
						rose = tick
					elseif up and not active then
						set = tick
					end
					up = active
				end
				assert(rose and set, `day {day}: a rise and a set`)
				-- Where the season's sun is when it rises: always the same place (Start on the sun's
				-- ticks), so it never rises in the daylight of a long summer evening.
				t.near(DayCycle.solarTimeInDay(rose), settings.Start, 10, `day {day}: rises at the sun's Start`)
				t.near(DayCycle.solarTimeInDay(set), settings.End, 10, `day {day}: sets at the sun's End`)
				t.eq(DayCycle.solarDay(rose), day, `day {day}: its own night`)
				t.eq(DayCycle.solarDay(set), day, `day {day}: to its end`)
				rises[season] = rose - day * DAY
				heights[season] = DayCycle.sunHeight(rose)
				-- Its intensity never jumps (a ramp each way).
				local last = 0
				for tick = rose - 100, set + 100, 5 do
					local value = BloodMoon.intensity(tick, settings)
					t.ok(math.abs(value - last) < 0.05, `day {day}: smooth at {tick}`)
					last = value
				end
			end
			for season = 2, 4 do
				t.near(heights[season], heights[1], 0.02, `the sun stands as low in season {season}`)
			end
			t.ok(rises[2] < rises[1] and rises[1] < rises[4], "earlier in winter, later in summer")
			-- The counter and its notices go by the same night: tonight's until it sets.
			t.eq(BloodMoon.daysUntil(14 * DAY + 6000, settings), 0)
			t.eq(BloodMoon.daysUntil(15 * DAY + 100, settings), 0, "a winter night past midnight is still tonight's")
		end)
	end)

	--[[ World/SeasonClock itself, with a fake day clock and workspace ]]

	local source = withHeader(fs.readFile(CLOCK))

	--[[
		Runs `fn(SeasonClock, clock)` with a fresh World/SeasonClock over a day clock at `dayTime`
		(`clock.now` moves it), then puts the calendar's module state back (the clock sets it).
	]]
	local function withClock(dayTime: number, fn: (any, any) -> ())
		local clock = { now = dayTime, attributes = {} :: { [string]: any } }
		local timeNode = { Name = "TimeOfDay" }
		local timeOfDay = {
			get = function(): number
				return clock.now
			end,
		}
		local game = {
			GetService = function(_, name: string): any
				assert(name == "ReplicatedStorage", `no fake service {name}`)
				return shared.Parent
			end,
		}
		local workspace = {
			SetAttribute = function(_, name: string, value: any)
				clock.attributes[name] = value
			end,
		}
		local Instance = {
			new = function(class: string): any
				assert(class == "BindableEvent", `no fake {class}`)
				return { Event = {}, Fire = function() end }
			end,
		}
		-- (The 60 s republishing loop never runs here.)
		local task = { spawn = function() end }
		local before = Calendar.state()
		local ok, err = pcall(function()
			local chunk = luau.load(source, { debugName = CLOCK })
			local SeasonClock = chunk(
				{ Name = "SeasonClock", Parent = { TimeOfDay = timeNode } },
				function(node: any): any
					return if node == timeNode then timeOfDay else require(node)
				end,
				game,
				workspace,
				Instance,
				task
			)
			fn(SeasonClock, clock)
		end)
		Calendar.setState(before)
		if not ok then
			error(err, 0)
		end
	end

	t.test(
		"seasons (World/SeasonClock): an unreadable calendar starts on Autumn's day 1 once the clock is back",
		function()
			-- A loaded world's sections in any order: the calendar first (it can't be read), then the
			-- day clock (a new server's clock until then).
			withClock(Config.Time.StartTime, function(SeasonClock, clock)
				SeasonClock.start()
				t.eq(SeasonClock.decode({ v = Calendar.VERSION, offset = "x" }), false)
				clock.now = 40 * DAY + 3000
				SeasonClock.restored()
				local p = SeasonClock.position()
				t.eq(p.season, Calendar.AUTUMN, "Autumn at the restored time (not day 40's Winter)")
				t.eq(p.day, 0)
				t.eq(clock.attributes[Calendar.ATTRIBUTE_OFFSET], -40, "published")
			end)
			-- A readable one stays as saved, whatever decoded first.
			withClock(Config.Time.StartTime, function(SeasonClock, clock)
				SeasonClock.start()
				t.eq(SeasonClock.decode(Calendar.encode(state(nil, -30), 40 * DAY)), true)
				clock.now = 40 * DAY + 3000
				SeasonClock.restored()
				t.eq(SeasonClock.position().calendarDay, 10, "the saved calendar")
			end)
			-- None at all (a new world): Autumn's first day.
			withClock(5 * DAY, function(SeasonClock)
				SeasonClock.start()
				SeasonClock.restored()
				t.eq(SeasonClock.position().calendarDay, 0)
			end)
		end
	)

	t.test(
		"seasons (World/SeasonClock): a world without seasons saves nothing new, then starts on Autumn's day 1",
		function()
			-- Played without seasons (no section, a hold set then): nothing saved.
			withClock(Config.Time.StartTime, function(SeasonClock, clock)
				SeasonClock.start(false)
				SeasonClock.restored()
				clock.now = 18 * DAY + 5000
				SeasonClock.setLocked(true)
				t.eq(SeasonClock.cycle(), false)
				t.eq(SeasonClock.encode(), nil, "no section")
			end)
			-- A section saved while it had seasons comes back unchanged, whatever happened meanwhile.
			local kept = Calendar.encode(state(nil, 5), 30 * DAY)
			withClock(Config.Time.StartTime, function(SeasonClock, clock)
				SeasonClock.start(false)
				t.eq(SeasonClock.decode(kept), true)
				SeasonClock.restored()
				clock.now = 50 * DAY
				SeasonClock.setLocked(true)
				SeasonClock.keepCalendar(50 * DAY, 1000)
				t.eq(SeasonClock.encode(), kept, "the section it had")
			end)
			-- The same world with seasons: no section, so Autumn's first day now, saved from there.
			withClock(18 * DAY + 5000, function(SeasonClock)
				SeasonClock.start()
				SeasonClock.restored()
				local p = SeasonClock.position()
				t.ok(p.season == Calendar.AUTUMN and p.day == 0, "Autumn's first day")
				local saved = SeasonClock.encode()
				t.eq(saved.v, Calendar.VERSION)
				t.eq(saved.day, 0)
			end)
		end
	)

	t.test("seasons (World/SeasonClock): doSeasonCycle moves neither the sun nor the calendar", function()
		withClock(8 * DAY + 11000, function(SeasonClock, clock)
			SeasonClock.start()
			SeasonClock.restored()
			-- Winter's first day (a blend day): Autumn's first was day 0.
			SeasonClock.setSeason(Calendar.WINTER, 1)
			local values = { 10, 20, 30, 40 }
			local solar, value = DayCycle.solarTime(clock.now), Calendar.value(values, clock.now)
			SeasonClock.setLocked(true)
			t.eq(SeasonClock.cycle(), false)
			t.eq(DayCycle.solarTime(clock.now), solar, "the sun stays")
			t.eq(Calendar.value(values, clock.now), value, "and what the season blends")
			t.eq(
				clock.attributes[Calendar.ATTRIBUTE_LOCK],
				Calendar.time(clock.now, state()),
				"the exact time, published"
			)
			-- A day later at the same time: the same; running on then, still the same.
			clock.now += DAY
			t.near(DayCycle.solarTime(clock.now) - DAY, solar, 1e-6)
			SeasonClock.setLocked(false)
			t.eq(SeasonClock.cycle(), true)
			t.near(DayCycle.solarTime(clock.now) - DAY, solar, 1e-6, "on: the sun")
			t.near(Calendar.value(values, clock.now), value, 1e-9, "on: the values")
			t.eq(SeasonClock.position().calendarDay, 8, "on from the held day")
		end)
	end)
end
