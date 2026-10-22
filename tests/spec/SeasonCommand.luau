--[[
	The seasons' commands (server Players/SeasonCommand, and Players/TimeCommand's part in them):
	/season query's wording ("It is Winter, day 3 of 8 (6 days left), year 1", the last day, a
	later year, a held calendar) for anyone, /season set's ("Set the season to Winter, day 1") for
	operators only, its season names and day checks, a world without seasons; /time set keeping the
	calendar (`keepCalendar`) while /time add moves it, /gamerule doSeasonCycle beside the other
	rules. Then the glue's rules played through Shared/Seasons/Calendar as server World/SeasonClock
	applies them: /time set never throws the world back to Autumn, /time add 8d is a season on,
	/season set keeps the time of day, the day count and the blood moons, doSeasonCycle false holds
	the season at the exact time it is through /time add and runs on from the held day.
]]

return function(t, shared, require, server)
	local BloodMoon = require(shared.Apocalypse.BloodMoon)
	local Calendar = require(shared.Seasons.Calendar)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local SeasonCommand = require(server.Players.SeasonCommand)
	local TimeCommand = require(server.Players.TimeCommand)

	local DAY = 24000

	local function state(offset: number?, lock: number?): Calendar.State
		local s = Calendar.newState()
		s.enabled = true
		s.offset = offset or 0
		s.lock = lock
		return s
	end

	-- A context at `dayTime` with `s` (default: Autumn's first day on day 0).
	local function context(mayUse: boolean, dayTime: number?, s: Calendar.State?, enabled: boolean?): any
		return { mayUse = mayUse, enabled = enabled ~= false, dayTime = dayTime or 1000, state = s or state() }
	end

	local function says(text: string, ctx: any): string
		local result = SeasonCommand.run(text, ctx)
		t.ok(result ~= nil, `{text}: a command`)
		t.eq(#result.feedback, 1, `{text}: one line`)
		return result.feedback[1]
	end

	t.test("season command: matching", function()
		t.ok(SeasonCommand.matches("/season query"))
		t.ok(SeasonCommand.matches("/SEASON"))
		t.ok(SeasonCommand.matches("  /season set winter"))
		t.ok(not SeasonCommand.matches("/seasons"))
		t.ok(not SeasonCommand.matches("what /season is it"))
		t.ok(not SeasonCommand.matches(""))
		t.eq(SeasonCommand.run("hello", context(true)), nil, "ordinary chat")
		t.eq(SeasonCommand.run("/time set day", context(true)), nil, "another command")
		t.eq(says("/season", context(true)), SeasonCommand.USAGE)
		t.eq(says("/season rewind", context(true)), SeasonCommand.USAGE)
		t.eq(says("/season query now", context(true)), SeasonCommand.QUERY_USAGE)
		t.eq(says("/season set", context(true)), SeasonCommand.SET_USAGE)
		t.eq(says("/season set winter 2 3", context(true)), SeasonCommand.SET_USAGE)
	end)

	t.test("season command: the query's wording, for anyone", function()
		-- (Calendar day 0 is Autumn's first: 8 day seasons by default.)
		t.eq(says("/season query", context(false, 1000)), "It is Autumn, day 1 of 8 (8 days left), year 1")
		t.eq(
			says("/season query", context(false, 10 * DAY + 5000)),
			"It is Winter, day 3 of 8 (6 days left), year 1",
			"the design's example"
		)
		t.eq(says("/season query", context(false, 7 * DAY)), "It is Autumn, day 8 of 8 (the last day), year 1")
		t.eq(says("/season query", context(false, 33 * DAY)), "It is Autumn, day 2 of 8 (7 days left), year 2")
		t.eq(says("/SEASON QUERY", context(false, 25 * DAY)), "It is Summer, day 2 of 8 (7 days left), year 1")
		-- An offset (a world that started later), and a held calendar.
		t.eq(
			says("/season query", context(false, 100 * DAY, state(-100))),
			"It is Autumn, day 1 of 8 (8 days left), year 1"
		)
		t.eq(
			says("/season query", context(false, 3 * DAY, state(0, 9))),
			`It is Winter, day 2 of 8 (7 days left), year 1; {SeasonCommand.HELD}`
		)
		t.eq(says("/season query", context(false, 1000, nil, false)), SeasonCommand.NO_SEASONS)
		-- (The wording for any position.)
		local p = Calendar.position(15 * DAY, state())
		t.eq(SeasonCommand.describe(p), "It is Winter, day 8 of 8 (the last day), year 1")
	end)

	t.test("season command: set, for operators only", function()
		local result = SeasonCommand.run("/season set winter", context(true)) :: any
		t.eq(result.season, Calendar.WINTER)
		t.eq(result.day, 1, "day 1 by default")
		t.eq(result.feedback[1], "Set the season to Winter, day 1")
		result = SeasonCommand.run("/season set Summer 5", context(true)) :: any
		t.ok(result.season == Calendar.SUMMER and result.day == 5, "any case, a day")
		t.eq(result.feedback[1], "Set the season to Summer, day 5")
		t.eq((SeasonCommand.run("/season set FALL 8", context(true)) :: any).season, Calendar.AUTUMN, "fall")
		t.eq((SeasonCommand.run("/season set spring 8", context(true)) :: any).day, 8, "the last day")
		-- Refusals: nothing set.
		local function refused(text: string, ctx: any): string
			local r = SeasonCommand.run(text, ctx) :: any
			t.eq(r.season, nil, text)
			t.eq(r.day, nil, text)
			return r.feedback[1]
		end
		t.eq(refused("/season set winter", context(false)), SeasonCommand.DENIED)
		t.eq(refused("/season set winter", context(true, 1000, nil, false)), SeasonCommand.NO_SEASONS)
		t.ok(string.find(refused("/season set monsoon", context(true)), "Unknown season 'monsoon'", 1, true))
		t.ok(string.find(refused("/season set winter 0", context(true)), "must not be less than 1", 1, true))
		t.ok(string.find(refused("/season set winter 9", context(true)), "must not be more than 8", 1, true))
		t.ok(string.find(refused("/season set winter 1.5", context(true)), "Expected a whole day", 1, true))
		t.ok(string.find(refused("/season set winter soon", context(true)), SeasonCommand.SET_USAGE, 1, true))
		-- (A longer season takes longer days.)
		local long = state()
		long.lengths = { 8, 20, 8, 8 }
		t.eq((SeasonCommand.run("/season set winter 20", context(true, 1000, long)) :: any).day, 20)
		t.eq(SeasonCommand.parseSeason("Winter"), Calendar.WINTER)
		t.eq(SeasonCommand.parseSeason("monsoon"), nil)
	end)

	t.test("time command (seasons): /time set keeps the calendar, /time add moves it, doSeasonCycle", function()
		local function ctx(seasonCycle: boolean?): any
			return { mayUse = true, dayTime = 5 * DAY + 3000, gameTime = 0, cycle = true, seasonCycle = seasonCycle }
		end
		local result = TimeCommand.run("/time set day", ctx()) :: any
		t.eq(result.dayTime, 1000)
		t.eq(result.keepCalendar, true, "/time set keeps the calendar")
		result = TimeCommand.run("/time add 8d", ctx()) :: any
		t.eq(result.dayTime, 13 * DAY + 3000)
		t.eq(result.keepCalendar, nil, "/time add moves it")
		t.eq((TimeCommand.run("/time query day", ctx()) :: any).keepCalendar, nil, "queries keep nothing")
		-- The rule, beside the others (an old context without it reads true).
		result = TimeCommand.run("/gamerule doSeasonCycle false", ctx()) :: any
		t.eq(result.seasonCycle, false)
		t.eq(result.cycle, nil, "the day goes on")
		t.eq(result.weatherCycle, nil)
		t.eq(result.feedback[1], "Gamerule doSeasonCycle is now set to: false")
		t.eq((TimeCommand.run("/gamerule doseasoncycle TRUE", ctx(false)) :: any).seasonCycle, true, "any case")
		t.eq(
			(TimeCommand.run("/gamerule doSeasonCycle", ctx(false)) :: any).feedback[1],
			"Gamerule doSeasonCycle is currently set to: false"
		)
		local old = { mayUse = true, dayTime = 1000, gameTime = 0, cycle = true }
		t.eq(
			(TimeCommand.run("/gamerule doSeasonCycle", old) :: any).feedback[1],
			"Gamerule doSeasonCycle is currently set to: true",
			"nil reads true"
		)
		local denied = TimeCommand.run(
			"/gamerule doSeasonCycle false",
			{ mayUse = false, dayTime = 0, gameTime = 0, cycle = true }
		) :: any
		t.eq(denied.seasonCycle, nil)
		t.eq(denied.feedback[1], TimeCommand.DENIED_RULES, "operators only")
		t.ok(table.find(TimeCommand.RULES, "doSeasonCycle") ~= nil)
		t.ok(string.find(TimeCommand.GAMERULE_USAGE, "doSeasonCycle", 1, true) ~= nil)
		t.ok(
			string.find(
				(TimeCommand.run("/gamerule keepInventory true", ctx()) :: any).feedback[1],
				"doSeasonCycle",
				1,
				true
			) ~= nil,
			"listed with the others"
		)
	end)

	--[[ The glue's rules, as World/SeasonClock applies them through the calendar ]]

	-- World/SeasonClock.keepCalendar.
	local function keepCalendar(s: Calendar.State, old: number, new: number): Calendar.State
		local next = table.clone(s)
		next.offset = Calendar.keep(old, new, s)
		return next
	end
	-- World/SeasonClock.setSeason (day 1-based).
	local function setSeason(s: Calendar.State, now: number, season: number, day: number): Calendar.State
		local offset, calendarDay = Calendar.offsetFor(season, day - 1, now, s)
		local next = table.clone(s)
		next.offset = offset
		local lock = next.lock
		if lock ~= nil then
			next.lock = calendarDay + (lock - math.floor(lock))
		end
		return next
	end
	-- World/SeasonClock.setLocked.
	local function setLocked(s: Calendar.State, now: number, on: boolean): Calendar.State
		return Calendar.hold(s, on, now)
	end
	-- What TimeCommands does with a command at `now`: the new state and day time.
	local function apply(text: string, s: Calendar.State, now: number): (Calendar.State, number)
		local result = TimeCommand.run(text, { mayUse = true, dayTime = now, gameTime = 0, cycle = true }) :: any
		local next = s
		if result.seasonCycle ~= nil then
			next = setLocked(next, now, not result.seasonCycle)
		end
		local dayTime = now
		if result.dayTime ~= nil then
			if result.keepCalendar then
				next = keepCalendar(next, now, result.dayTime)
			end
			dayTime = result.dayTime
		end
		return next, dayTime
	end

	t.test("season command (glue): /time set keeps the season, /time add 8d moves it", function()
		local s, now = state(), 20 * DAY + 4000
		local before = Calendar.position(now, s)
		t.eq(before.season, Calendar.SPRING, "day 20: Spring")
		-- /time set day: day 0 again, the same calendar day (Minecraft 1.20 restarts the count).
		local kept, dayTime = apply("/time set day", s, now)
		t.eq(dayTime, 1000)
		t.eq(DayCycle.day(dayTime), 0, "the day count starts over")
		local after = Calendar.position(dayTime, kept)
		t.eq(after.calendarDay, before.calendarDay, "never back to Autumn")
		t.eq(after.season, Calendar.SPRING)
		-- /time set to a later day number too.
		kept, dayTime = apply("/time set 100000", s, now)
		t.eq(Calendar.position(dayTime, kept).calendarDay, before.calendarDay)
		-- /time add 8d: a season on, at the default lengths.
		local moved, later = apply("/time add 8d", s, now)
		t.eq(moved.offset, s.offset, "the offset stays")
		t.eq(Calendar.position(later, moved).season, Calendar.SUMMER, "Spring + 8 days: Summer")
		t.eq(Calendar.position(later, moved).day, before.day, "the same day of it")
		-- /time add of part of a day crosses the calendar's day with the clock's.
		local _, soon = apply("/time add 0.9d", s, now)
		t.eq(Calendar.day(soon, s), Calendar.day(now, s) + 1)
	end)

	t.test("season command (glue): /season set keeps the time of day, the day count and the blood moons", function()
		local s, now = state(), 30 * DAY + 13500
		local result = SeasonCommand.run("/season set winter 3", context(true, now, s)) :: any
		local set = setSeason(s, now, result.season, result.day)
		local p = Calendar.position(now, set)
		t.eq(p.season, Calendar.WINTER)
		t.eq(p.day, 2, "day 3 (1-based)")
		t.eq(p.year, Calendar.position(now, s).year, "the year it is")
		-- Only the offset moved: the day time, the "Day N" line and the blood moons are the clock's.
		t.eq(DayCycle.day(now), 30)
		t.eq(DayCycle.timeInDay(now), 13500)
		local settings = Config.Apocalypse.BloodMoon
		local before = Calendar.state()
		Calendar.setState(s)
		local moonBefore = BloodMoon.daysUntil(now, settings)
		Calendar.setState(set)
		local moonAfter = BloodMoon.daysUntil(now, settings)
		Calendar.setState(before)
		t.eq(moonAfter, moonBefore, "the blood moon schedule stays")
		-- Every season and day lands where asked.
		for season = 1, 4 do
			for day = 1, 8 do
				local at = Calendar.position(now, setSeason(s, now, season, day))
				t.ok(at.season == season and at.day == day - 1, `season {season} day {day}`)
			end
		end
	end)

	t.test("season command (glue): doSeasonCycle false holds the season, true runs on from it", function()
		local s, now = state(), 3 * DAY + 2000
		local held = apply("/gamerule doSeasonCycle false", s, now)
		t.eq(Calendar.day(now, held), 3, "held on the day it is")
		t.eq(held.lock, Calendar.time(now, s), "at the exact time it is")
		-- A week passes, and /time add 8d: still Autumn's fourth day.
		local later = now + 7 * DAY
		local _, added = apply("/time add 8d", held, later)
		t.eq(Calendar.position(added, held).calendarDay, 3, "held through the days and /time add")
		-- /season set while held moves the held day (its time of day stays).
		local set = setSeason(held, added, Calendar.SUMMER, 2)
		t.eq(Calendar.position(added, set).season, Calendar.SUMMER)
		t.eq(Calendar.day(added, set), Calendar.seasonStart(Calendar.SUMMER, s) + 1)
		t.near((set.lock :: number) % 1, 2000 / DAY, 1e-9)
		-- On again: from the held day.
		local running = apply("/gamerule doSeasonCycle true", set, added)
		t.eq(running.lock, nil)
		t.eq(Calendar.day(added, running), Calendar.day(added, set), "runs on from the held day")
		t.eq(Calendar.day(added + DAY, running), Calendar.day(added, set) + 1)
	end)
end
