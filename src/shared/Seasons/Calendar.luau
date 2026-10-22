--!strict
--[[
	The seasons' calendar, pure: Don't Starve's Autumn, Winter, Spring and Summer (Config.Seasons),
	worked out from the day time (Shared/DayCycle's ticks) and one published number, the offset.

	  Calendar day  `day(dayTime)`: DayCycle's day (floor(dayTime / 24000)) plus `offset`, a whole
	                number of days, the only state (saved with the world by server World/SeasonClock
	                and published as workspace attributes). It exists so that /time set keeps the
	                season (`keep`: the offset takes the day's jump back), /time add 8d moves it on
	                and /season set changes only the offset (`offsetFor`): the blood moons and the
	                "Day N" line, which go by the day time alone, stay put. While doSeasonCycle is
	                off (`lock`) the calendar stands on the held day.
	  Calendar time `time(dayTime)`: the calendar day plus the share of the day gone (a day starts
	                at sunrise, tick 0), continuous; held, the calendar time it was held at (`lock`),
	                so nothing a season blends moves while the calendar stands.
	  Holding       `hold(s, on, dayTime)` (doSeasonCycle): held, the calendar stands at its exact
	                time then, so nothing it blends moves at that moment and the sun keeps the share
	                of the solar day it is in; running again, it goes on from the held day at the
	                time of day it is. The offset stays whole (a season still turns at sunrise), so
	                running on at another time of day than the held one moves what a blend day
	                blends by the hours between them; the sun keeps its share while both times are
	                on the same side of midnight.
	  Position      `position(dayTime)` / `at(time)`: the year (0-based), the season (AUTUMN 1 ..
	                SUMMER 4), the day in it (0-based; `daysLeft` counts today: 1 on its last day),
	                its length, the progress through the season and through the year (0..1). Year 0
	                starts with Autumn's first day on calendar day 0; negative days count back
	                through earlier years. The season turns at sunrise of its first day.
	  Blending      `value(perSeason, dayTime)`: a quantity given per season blends with a
	                smoothstep over Config.Seasons.BlendDays centred on each turn (the old season's
	                last day and the new one's first: about 40 minutes of play at the default
	                lengths), so nothing ever steps. BlendDays is at most the shortest season.
	  The sun       `daylightScale(dayTime)`: k, the day half's share of half a day, per *solar*
	                day (midnight to midnight, 18000 to 18000 ticks: the value at that day's noon,
	                kept within MIN_SCALE..MAX_SCALE; held, the one of the solar day the calendar
	                was held in), so it changes only at midnight. `solarTime` warps the time within
	                each solar day piecewise linearly: noon (6000) and midnight (18000) stay where
	                they are, the day half (around noon) spans k x half the real day and the night
	                half the rest. It is continuous and only grows, and the identity with the
	                seasons off or k = 1. DayCycle's sun follows it (DayCycle.timeOfDay), so the day
	                length (Config.Time.DayLength) and the closed form clock never change: winter's
	                sun only sets earlier.
	  State         `newState()` (Config's lengths, offset 0, running), `setState` / `state` (the
	                module's own, as Weather.setSeed: every function's `s` defaults to it). The
	                module's state starts disabled (every rule the identity) until something sets
	                it: the server's World/SeasonClock at its start, the client's
	                Rendering/LightingController from the attributes (`readAttributes`, which says
	                disabled before the server published anything).
	  Saving        `encode(s, dayTime, kept)`: { v, offset, lock, lengths, day } (the calendar day
	                when saved): version 1 whenever it can say it (running, or held at a day's
	                middle: that whole day its lock), byte for byte what the builds before the exact
	                hold wrote, so they read it back; version 2 only for a hold at another time of
	                day (its exact calendar time). A world without seasons (`s.enabled` false) saves
	                nothing of its own but `kept`, what it had saved (nil: nothing), so neither the
	                days played without them nor a hold set then count: one that never had them
	                starts on Autumn's first day the first time they are on, one that had them on
	                the day it was saved on. `decode(v, s, dayTime)` gives it back (version 1's lock,
	                a whole day, held at that day's middle as it was), re-anchored when Config's
	                lengths changed since: the season is kept, its first day stays its first and its
	                last its last (the days between in proportion), and the offset is worked out
	                again from the saved day alone, so it does not depend on the order
	                World/WorldSave's sections decode in; with `dayTime` (the day clock restored:
	                World/SeasonClock.restored) it puts that on the day the save was made on, however
	                far the day clock ran on since.
	  Attributes    `writeAttributes(s, set)` / `readAttributes(get)`: ATTRIBUTE_ENABLED (bool),
	                ATTRIBUTE_OFFSET (days), ATTRIBUTE_LOCK (the held calendar time, absent while
	                running) and ATTRIBUTE_LENGTHS ("8,8,8,8").

	Requires only Config: Shared/DayCycle requires this (its sun's warp), never the reverse.
]]

local Config = require(script.Parent.Parent.Config)

local Calendar = {}

Calendar.AUTUMN = 1
Calendar.WINTER = 2
Calendar.SPRING = 3
Calendar.SUMMER = 4
Calendar.NAMES = table.freeze({ "Autumn", "Winter", "Spring", "Summer" })
Calendar.SEASONS = 4

-- Workspace attributes the server publishes (World/SeasonClock).
Calendar.ATTRIBUTE_ENABLED = "IceVoxelSeasonsEnabled"
Calendar.ATTRIBUTE_OFFSET = "IceVoxelSeasonOffset"
Calendar.ATTRIBUTE_LOCK = "IceVoxelSeasonLock"
Calendar.ATTRIBUTE_LENGTHS = "IceVoxelSeasonLengths"

-- DayCycle's ticks a day (this module can't require DayCycle, which requires it).
Calendar.TICKS_PER_DAY = 24000
-- Noon and midnight (ticks into the day): the warp's fixed points.
Calendar.NOON = 6000
Calendar.MIDNIGHT = 18000
-- The sun's day share stays within these (`daylightScale`).
Calendar.MIN_SCALE = 0.6
Calendar.MAX_SCALE = 1.4
-- The longest season (days) a state may have.
Calendar.MAX_LENGTH = 1000
-- The save's newest version (`encode` writes 1 whenever it can: running, or held at a day's
-- middle, version 1's lock being that whole day).
Calendar.VERSION = 2

export type State = {
	-- false: every rule is the identity (no seasons).
	enabled: boolean,
	-- Days added to DayCycle's day (a whole number).
	offset: number,
	-- The calendar time (days, continuous) it stands at while doSeasonCycle is off (nil: running).
	lock: number?,
	-- Days of Autumn, Winter, Spring and Summer (whole, 1..MAX_LENGTH).
	lengths: { number },
}

export type Position = {
	-- DayCycle's day + offset (or the held day), and the continuous calendar time.
	calendarDay: number,
	time: number,
	-- 0-based year (shown as year + 1).
	year: number,
	-- AUTUMN 1 .. SUMMER 4.
	season: number,
	-- 0-based day of the season (shown as day + 1), its length, the days left counting today.
	day: number,
	days: number,
	daysLeft: number,
	-- 0..1 through the season and through the year (by days: an unequal year's share).
	progress: number,
	yearProgress: number,
}

-- A save (`encode`).
export type Saved = { v: number, offset: number, lock: number?, lengths: { number }, day: number }

local TICKS = Calendar.TICKS_PER_DAY
local floor, clamp = math.floor, math.clamp

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function whole(value: any): boolean
	return finite(value) and value == floor(value)
end

-- Are `lengths` four whole numbers 1..MAX_LENGTH?
local function validLengths(lengths: any): boolean
	if type(lengths) ~= "table" or #lengths ~= Calendar.SEASONS then
		return false
	end
	for i = 1, Calendar.SEASONS do
		local length = lengths[i]
		if not whole(length) or length < 1 or length > Calendar.MAX_LENGTH then
			return false
		end
	end
	return true
end
Calendar.validLengths = validLengths

local function configLengths(): { number }
	local lengths = Config.Seasons.Lengths
	assert(validLengths(lengths), "Config.Seasons.Lengths must be four whole numbers of days, 1..1000")
	return { lengths[1], lengths[2], lengths[3], lengths[4] }
end

do
	local lengths = configLengths()
	local blend = Config.Seasons.BlendDays
	assert(
		finite(blend) and blend >= 0 and blend <= math.min(lengths[1], lengths[2], lengths[3], lengths[4]),
		"Config.Seasons.BlendDays must be 0..the shortest season"
	)
end

-- A fresh state: Config's switch and lengths, offset 0, running.
function Calendar.newState(): State
	return { enabled = Config.Seasons.Enabled == true, offset = 0, lock = nil, lengths = configLengths() }
end

--[[
	The calendar of a world that has none saved (a new world, or one saved before the seasons): a
	fresh state whose offset puts `dayTime` on calendar day 0, Autumn's first day, so every world
	gets the same 8 mild days before its first winter.
]]
function Calendar.fresh(dayTime: number): State
	local s = Calendar.newState()
	s.offset = -floor(dayTime / TICKS)
	return s
end

-- The module's state (see the header): disabled until set.
local current: State = Calendar.newState()
current.enabled = false
-- Bumped by every setState (the sun's cache follows it).
local version = 0

-- Makes `s` the module's state (a valid state: whole offset, lengths of four whole days).
function Calendar.setState(s: State)
	assert(type(s) == "table" and validLengths(s.lengths), "Calendar.setState needs four whole lengths")
	assert(whole(s.offset), "Calendar.setState needs a whole offset")
	assert(s.lock == nil or finite(s.lock), "Calendar.setState needs a finite held time")
	current = s
	version += 1
end

-- The module's state (read only: give a changed copy to setState).
function Calendar.state(): State
	return current
end

-- Days in a year of `s`.
function Calendar.yearLength(s: State?): number
	local lengths = (s or current).lengths
	return lengths[1] + lengths[2] + lengths[3] + lengths[4]
end

-- The calendar day of the first day of `season` within a year (Autumn's is 0).
function Calendar.seasonStart(season: number, s: State?): number
	local lengths = (s or current).lengths
	local start = 0
	for i = 1, season - 1 do
		start += lengths[i]
	end
	return start
end

-- The calendar day (whole) at `dayTime`: DayCycle's day plus the offset, or the held day.
function Calendar.day(dayTime: number, s: State?): number
	local state = s or current
	local lock = state.lock
	if lock ~= nil then
		return floor(lock)
	end
	return floor(dayTime / TICKS) + state.offset
end

-- The calendar time (days, continuous) at `dayTime` (see the header).
function Calendar.time(dayTime: number, s: State?): number
	local state = s or current
	local lock = state.lock
	if lock ~= nil then
		return lock
	end
	return dayTime / TICKS + state.offset
end

-- The season holding day `r` (0 <= r < a year) of a year, and that season's first day.
local function seasonOf(lengths: { number }, r: number): (number, number)
	local start = 0
	for season = 1, Calendar.SEASONS - 1 do
		local length = lengths[season]
		if r < start + length then
			return season, start
		end
		start += length
	end
	return Calendar.SEASONS, start
end

-- The position at calendar time `time` (see the header), written into `into` when given.
function Calendar.at(time: number, s: State?, into: Position?): Position
	local state = s or current
	local lengths = state.lengths
	local yearLength = lengths[1] + lengths[2] + lengths[3] + lengths[4]
	local year = floor(time / yearLength)
	local r = time - year * yearLength
	if r >= yearLength then
		-- (Rounding of a time just under a year's end.)
		r = yearLength - 1e-9
	elseif r < 0 then
		r = 0
	end
	local season, start = seasonOf(lengths, r)
	local days = lengths[season]
	local into_ = r - start
	local day = math.min(floor(into_), days - 1)
	local position: Position = into
		or {
			calendarDay = 0,
			time = 0,
			year = 0,
			season = 1,
			day = 0,
			days = 1,
			daysLeft = 1,
			progress = 0,
			yearProgress = 0,
		}
	position.calendarDay = floor(time)
	position.time = time
	position.year = year
	position.season = season
	position.day = day
	position.days = days
	position.daysLeft = days - day
	position.progress = clamp(into_ / days, 0, 1)
	position.yearProgress = clamp(r / yearLength, 0, 1)
	return position
end

-- The position at `dayTime`.
function Calendar.position(dayTime: number, s: State?, into: Position?): Position
	local state = s or current
	return Calendar.at(Calendar.time(dayTime, state), state, into)
end

local function smoothstep(x: number): number
	if x <= 0 then
		return 0
	elseif x >= 1 then
		return 1
	end
	return x * x * (3 - 2 * x)
end
Calendar.smoothstep = smoothstep

-- Days the quantities blend over for `lengths` (Config's BlendDays, at most the shortest season).
local function blendDays(lengths: { number }): number
	local blend = math.max(Config.Seasons.BlendDays, 0)
	return math.min(blend, lengths[1], lengths[2], lengths[3], lengths[4])
end

--[[
	`perSeason` (Autumn, Winter, Spring, Summer) at calendar time `time` with `s`: the season's
	value, blended with the season before over the first BlendDays / 2 and with the next over the
	last (smoothstep; halfway at the turn). Disabled states blend the same: callers decide whether
	seasons count (`enabled`).
]]
function Calendar.valueAt(perSeason: { number }, time: number, s: State?): number
	local state = s or current
	local lengths = state.lengths
	local yearLength = lengths[1] + lengths[2] + lengths[3] + lengths[4]
	local r = time - floor(time / yearLength) * yearLength
	local season, start = seasonOf(lengths, r)
	local into = r - start
	local length = lengths[season]
	local here = perSeason[season]
	local blend = blendDays(lengths)
	if blend <= 0 then
		return here
	end
	local half = blend / 2
	if into < half then
		local before = perSeason[if season == 1 then Calendar.SEASONS else season - 1]
		return before + (here - before) * smoothstep((into + half) / blend)
	elseif length - into < half then
		local after = perSeason[if season == Calendar.SEASONS then 1 else season + 1]
		return here + (after - here) * smoothstep((into - (length - half)) / blend)
	end
	return here
end

-- `perSeason` at `dayTime` (`valueAt` of `time(dayTime)`).
function Calendar.value(perSeason: { number }, dayTime: number, s: State?): number
	local state = s or current
	return Calendar.valueAt(perSeason, Calendar.time(dayTime, state), state)
end

-- The solar day (midnight to midnight) holding `dayTime`: the DayCycle day of its noon.
local function solarDayOf(dayTime: number): number
	return floor((dayTime + (TICKS - Calendar.MIDNIGHT)) / TICKS)
end

-- The calendar time of the noon of the solar day holding calendar time `time` (the offset is
-- whole: the calendar's time of day is the clock's).
local function solarNoon(time: number): number
	return floor(time + (TICKS - Calendar.MIDNIGHT) / TICKS) + Calendar.NOON / TICKS
end

-- (The module state's k by solar day: it changes only with the state.)
local cachedVersion, cachedDay, cachedScale = -1, 0, 1

local function scaleOf(day: number, state: State): number
	local lock = state.lock
	-- (Held, every solar day is the one the calendar was held in: the sun keeps its share.)
	local noon = if lock ~= nil then solarNoon(lock) else Calendar.time(day * TICKS + Calendar.NOON, state)
	local k = Calendar.valueAt(Config.Seasons.DaylightScale, noon, state)
	return clamp(k, Calendar.MIN_SCALE, Calendar.MAX_SCALE)
end

-- k, the sun's day share for the solar day holding `dayTime` (1 with the seasons off).
function Calendar.daylightScale(dayTime: number, s: State?): number
	local state = s or current
	if not state.enabled then
		return 1
	end
	local day = solarDayOf(dayTime)
	if s == nil then
		if cachedVersion ~= version or cachedDay ~= day then
			cachedVersion, cachedDay, cachedScale = version, day, scaleOf(day, state)
		end
		return cachedScale
	end
	return scaleOf(day, state)
end

-- The warped day time (ticks) of `dayTime`: see the header. The identity when disabled or k = 1.
function Calendar.solarTime(dayTime: number, s: State?): number
	local state = s or current
	if not state.enabled then
		return dayTime
	end
	local k = Calendar.daylightScale(dayTime, s)
	if k == 1 then
		return dayTime
	end
	local day = solarDayOf(dayTime)
	local base = day * TICKS
	local r = dayTime - base
	local noon = Calendar.NOON
	local half = noon * k
	-- (Each night half: 12000 - half real ticks for 6000 of the sun's.)
	local nightRate = noon / (2 * noon - half)
	local solar
	if r < noon - half then
		solar = -noon + (r + noon) * nightRate
	elseif r <= noon + half then
		solar = noon + (r - noon) / k
	else
		solar = 2 * noon + (r - noon - half) * nightRate
	end
	return base + solar
end

--[[
	The offset putting `dayTime` on day `day` (0-based, within the season's length) of `season`
	in the year it is in now, so only the season moves (the time of day stays). Returns the offset
	and that calendar day (the held day while held).
]]
function Calendar.offsetFor(season: number, day: number, dayTime: number, s: State): (number, number)
	assert(season >= 1 and season <= Calendar.SEASONS and season == floor(season), "Calendar.offsetFor: bad season")
	local position = Calendar.position(dayTime, s)
	local length = s.lengths[season]
	local target = position.year * Calendar.yearLength(s)
		+ Calendar.seasonStart(season, s)
		+ clamp(floor(day), 0, length - 1)
	return target - floor(dayTime / TICKS), target
end

-- The offset that keeps the calendar day across a jump of the day time from `oldDayTime` to
-- `newDayTime` (/time set).
function Calendar.keep(oldDayTime: number, newDayTime: number, s: State): number
	return s.offset + floor(oldDayTime / TICKS) - floor(newDayTime / TICKS)
end

--[[
	`s` held (`on`: doSeasonCycle false) or running again (doSeasonCycle true) at `dayTime`: a new
	state, or `s` itself when it already is (see the header).
]]
function Calendar.hold(s: State, on: boolean, dayTime: number): State
	local lock = s.lock
	if on == (lock ~= nil) then
		return s
	end
	local next = table.clone(s)
	if lock == nil then
		next.lock = Calendar.time(dayTime, s)
	else
		-- (On from the held day.)
		next.offset = floor(lock) - floor(dayTime / TICKS)
		next.lock = nil
	end
	return next
end

-- The save of `s` at `dayTime`, or `kept` with the seasons off (see the header).
function Calendar.encode(s: State, dayTime: number, kept: any?): Saved?
	if not s.enabled then
		return kept
	end
	local lock = s.lock
	-- (What version 1 can say, it says: running, or held at a whole day's middle, its day.)
	local old = lock == nil or whole(lock - 0.5)
	return {
		v = if old then 1 else Calendar.VERSION,
		offset = s.offset,
		lock = if lock ~= nil and old then lock - 0.5 else lock,
		lengths = table.clone(s.lengths),
		day = Calendar.day(dayTime, s),
	}
end

-- Calendar day `day` of a year with `from` lengths, moved to the same season of a year with `to`
-- lengths: its first day to the first, its last to the last, the days between in proportion.
local function reanchor(day: number, from: { number }, to: { number }): number
	local fromState: State = { enabled = true, offset = 0, lengths = from }
	local toState: State = { enabled = true, offset = 0, lengths = to }
	local position = Calendar.at(day + 0.5, fromState)
	local season = position.season
	local fromLength, toLength = from[season], to[season]
	local inSeason = if fromLength > 1 then floor(position.day * (toLength - 1) / (fromLength - 1) + 0.5) else 0
	return position.year * Calendar.yearLength(toState) + Calendar.seasonStart(season, toState) + inSeason
end

--[[
	The state a save `v` (`encode`) gives back over `s` (Config's: its switch and lengths are
	kept): its offset and lock, re-anchored when the saved lengths differ (see the header). With
	`dayTime`, the day clock it is restored to, the offset puts that on the calendar day the save
	was made on. nil when `v` is no save of this version or the one before.
]]
function Calendar.decode(v: any, s: State, dayTime: number?): State?
	if type(v) ~= "table" or (v.v ~= Calendar.VERSION and v.v ~= 1) then
		return nil
	end
	local offset, day, lock, lengths = v.offset, v.day, v.lock, v.lengths
	local lockOk = lock == nil or (if v.v == 1 then whole(lock) else finite(lock))
	if not whole(offset) or not whole(day) or not lockOk or not validLengths(lengths) then
		return nil
	end
	if lock ~= nil and v.v == 1 then
		-- (Version 1 held a whole day, at its middle.)
		lock += 0.5
	end
	local state: State = { enabled = s.enabled, offset = offset, lock = lock, lengths = table.clone(s.lengths) }
	local same = true
	for i = 1, Calendar.SEASONS do
		if lengths[i] ~= s.lengths[i] then
			same = false
		end
	end
	-- (The calendar day it was saved on, in Config's lengths.)
	local anchored = day
	if not same then
		local saved = { lengths[1], lengths[2], lengths[3], lengths[4] }
		anchored = reanchor(day, saved, s.lengths)
		-- (The world's own day when saved stays: day - offset.)
		state.offset = offset + anchored - day
		if lock ~= nil then
			-- (The held day moves, its time of day stays.)
			local heldDay = floor(lock)
			state.lock = reanchor(heldDay, saved, s.lengths) + (lock - heldDay)
		end
	end
	if dayTime ~= nil then
		-- (On that day again, however far the day clock ran on since the section was written: a
		-- world played without seasons keeps the one it had.)
		state.offset = anchored - floor(dayTime / TICKS)
	end
	return state
end

-- Writes `s` with `set(name, value)` (workspace:SetAttribute; nil removes the lock).
function Calendar.writeAttributes(s: State, set: (string, any) -> ())
	set(Calendar.ATTRIBUTE_ENABLED, s.enabled)
	set(Calendar.ATTRIBUTE_OFFSET, s.offset)
	set(Calendar.ATTRIBUTE_LOCK, s.lock)
	set(Calendar.ATTRIBUTE_LENGTHS, table.concat(s.lengths, ","))
end

--[[
	The state the attributes describe, read with `get(name)` (workspace:GetAttribute), into `into`
	when given. Before the server published anything: disabled. Malformed numbers read as 0 and
	running, malformed lengths as Config's.
]]
function Calendar.readAttributes(get: (string) -> any, into: State?): State
	local state = into or Calendar.newState()
	state.enabled = get(Calendar.ATTRIBUTE_ENABLED) == true
	local offset = get(Calendar.ATTRIBUTE_OFFSET)
	state.offset = if whole(offset) then offset else 0
	local lock = get(Calendar.ATTRIBUTE_LOCK)
	state.lock = if finite(lock) then lock else nil
	local lengths: { number }? = nil
	local text = get(Calendar.ATTRIBUTE_LENGTHS)
	if type(text) == "string" then
		local parts = string.split(text, ",")
		local parsed: { any } = {}
		for i, part in parts do
			parsed[i] = tonumber(part)
		end
		if validLengths(parsed) then
			lengths = parsed :: { number }
		end
	end
	state.lengths = lengths or configLengths()
	return state
end

return Calendar
