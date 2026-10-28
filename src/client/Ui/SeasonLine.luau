--!strict
--[[
	What the season clock says and when the seasons' toasts come (pure: numbers in, text out, so
	the tests read every case), as Ui/SurvivorLine does for the day line. Ui/SeasonHud draws it;
	Shared/Seasons/Calendar is the calendar both sides work out from the day time and the
	published offset, Shared/Seasons/SeasonClimate the heat waves (the world's seed).

	  Caption   under the dial, upper case (Ui/Theme's caps): "WINTER · 3 DAYS LEFT" (the days left
	            count today), "LAST DAY OF AUTUMN" on a season's last day, "HEAT WAVE" (Theme's
	            Warn) on a heat wave's day from dawn until its heat is over (`heatWaveShown`: until
	            the wave's To, where SeasonClimate.heatWave's heat ends), and the season's name
	            alone while /gamerule doSeasonCycle false holds the calendar (no days run out). Its
	            colour is the season's (Theme.Season). `captionWidth`: GUI pixels in WIDTH_STEP
	            steps, so a changing digit doesn't move the clock every day; `captions` lists every
	            caption a calendar can show (the widest is what the HUD's layout is tested with).
	  Toasts    `events(before, now)` from one look at the clock to the next: the season's turn at
	            the sunrise (tick 0) of its first day, the moment its label turns ("Autumn · the
	            leaves turn", "Winter has come · 8 days", "Spring · the thaw begins", "Summer ·
	            heat waves ahead"), and a heat wave's dawn ("Heat wave · seek shade"). A step
	            back in time or of more than MAX_STEP ticks (a /time set, a long hitch) is no event,
	            and neither is a look whose calendar is not the one the look before read (`earlier`:
	            /time set keeping the calendar, /season set, the lock), so nothing already toasted
	            comes again; the next look goes on as ever. With the calendar off there are none.
	            Each has its colour key (`colourKey`) and its stinger (`sound`:
	            ambient.season.<name>, heat_wave), and goes through Ui/SurvivorHud's one toast
	            queue with the blood moon's notices.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Calendar = require(Shared.Seasons.Calendar)
local Config = require(Shared.Config)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)

export type EventKind = "season" | "heatWave"
-- A toast: a season's turn (`season` the new one) or a heat wave's dawn (`season` Summer's).
export type Event = { kind: EventKind, season: number }

local SeasonLine = {}

-- Ticks one look may move the clock and still be watched for events (as Ui/SurvivorLine).
SeasonLine.MAX_STEP = 600
-- Between a caption's season and its days left.
SeasonLine.GAP = " · "
-- GUI pixels the caption's width moves in.
SeasonLine.WIDTH_STEP = 8
-- The caption of a heat wave's day, and its colour key (Ui/Theme).
SeasonLine.HEAT_WAVE = "HEAT WAVE"
SeasonLine.HEAT_WAVE_COLOUR = "Warn"
-- The seasons' colour keys (Ui/Theme.Season's) by season number.
SeasonLine.COLOURS = table.freeze({ "SeasonAutumn", "SeasonWinter", "SeasonSpring", "SeasonSummer" })
-- The turns' toasts by season number (Winter's says how long it lasts: `toastText`).
SeasonLine.TOASTS = table.freeze({
	"Autumn · the leaves turn",
	"Winter has come · %s",
	"Spring · the thaw begins",
	"Summer · heat waves ahead",
})
SeasonLine.HEAT_WAVE_TOAST = "Heat wave · seek shade"
-- The stingers (the Survival pack's sounds), by season number, and a heat wave's.
SeasonLine.SOUNDS = table.freeze({
	"ambient.season.autumn",
	"ambient.season.winter",
	"ambient.season.spring",
	"ambient.season.summer",
})
SeasonLine.HEAT_WAVE_SOUND = "ambient.season.heat_wave"

local TICKS = Calendar.TICKS_PER_DAY

local function days(n: number): string
	return if n == 1 then "1 day" else `{n} days`
end

--[[
	Is a heat wave's caption up at `dayTime` with the world's `seed` (`s` defaults to the
	calendar's state): a heat wave's day (SeasonClimate.isHeatWave of the calendar day, which
	stands while the calendar is held) until its heat is over.
]]
function SeasonLine.heatWaveShown(dayTime: number, seed: number, s: Calendar.State?): boolean
	local state = s or Calendar.state()
	if not state.enabled then
		return false
	end
	local ticks = dayTime - math.floor(dayTime / TICKS) * TICKS
	if ticks >= Config.Seasons.Climate.HeatWave.To then
		return false
	end
	return SeasonClimate.isHeatWave(Calendar.day(dayTime, state), seed, state)
end

--[[
	The caption at `position` (Calendar.Position) and its colour key (see the header): `heatWave`
	a heat wave's caption is up, `held` the calendar stands still (doSeasonCycle false).
]]
function SeasonLine.caption(position: Calendar.Position, heatWave: boolean, held: boolean): (string, string)
	if heatWave then
		return SeasonLine.HEAT_WAVE, SeasonLine.HEAT_WAVE_COLOUR
	end
	local name = string.upper(Calendar.NAMES[position.season])
	local key = SeasonLine.COLOURS[position.season]
	if held then
		return name, key
	elseif position.daysLeft <= 1 then
		return `LAST DAY OF {name}`, key
	end
	return `{name}{SeasonLine.GAP}{position.daysLeft} DAYS LEFT`, key
end

--[[
	Every caption a calendar with `s`'s lengths can show (each season's days left, its last day,
	held, the heat wave), for measuring the widest.
]]
function SeasonLine.captions(s: Calendar.State?): { string }
	local state = s or Calendar.state()
	local list = { SeasonLine.HEAT_WAVE }
	for season = 1, Calendar.SEASONS do
		local name = string.upper(Calendar.NAMES[season])
		table.insert(list, name)
		table.insert(list, `LAST DAY OF {name}`)
		for left = 2, state.lengths[season] do
			table.insert(list, `{name}{SeasonLine.GAP}{left} DAYS LEFT`)
		end
	end
	return list
end

-- The caption's width (GUI pixels) for `text`, `measure` giving its width (with the outline's pixel).
function SeasonLine.captionWidth(text: string, measure: (text: string) -> number): number
	local step = SeasonLine.WIDTH_STEP
	return math.ceil((measure(text) + 1) / step) * step
end

-- Do `a` and `b` describe the same calendar (the switch, the offset, the lock, the lengths)?
local function sameCalendar(a: Calendar.State, b: Calendar.State): boolean
	if a == b then
		return true
	elseif a.enabled ~= b.enabled or a.offset ~= b.offset or a.lock ~= b.lock then
		return false
	end
	for i = 1, Calendar.SEASONS do
		if a.lengths[i] ~= b.lengths[i] then
			return false
		end
	end
	return true
end

--[[
	The toasts due between day times `before` (nil: the first look) and `now` (see the header),
	`s` the calendar now (default the calendar's state) and `earlier` the one `before` was read
	with (default `s`).
]]
function SeasonLine.events(
	before: number?,
	now: number,
	seed: number,
	s: Calendar.State?,
	earlier: Calendar.State?
): { Event }
	local events: { Event } = {}
	local state = s or Calendar.state()
	if not state.enabled or before == nil or now < before or now - before > SeasonLine.MAX_STEP then
		return events
	end
	-- (The calendar itself changed between the looks: its turns are not the clock's.)
	if earlier ~= nil and not sameCalendar(earlier, state) then
		return events
	end
	-- (Seasons turn and heat waves come at sunrise, tick 0, when the calendar's day changes.)
	if math.floor(now / TICKS) == math.floor(before / TICKS) then
		return events
	end
	local was, is = Calendar.position(before, state), Calendar.position(now, state)
	if is.season ~= was.season and is.day == 0 then
		table.insert(events, { kind = "season", season = is.season })
	end
	if SeasonClimate.isHeatWave(Calendar.day(now, state), seed, state) then
		table.insert(events, { kind = "heatWave", season = is.season })
	end
	return events
end

-- The toast of `event`, with `s`'s lengths (Winter's says how long it lasts).
function SeasonLine.toastText(event: Event, s: Calendar.State?): string
	if event.kind == "heatWave" then
		return SeasonLine.HEAT_WAVE_TOAST
	end
	local text = SeasonLine.TOASTS[event.season]
	if event.season == Calendar.WINTER then
		local state = s or Calendar.state()
		text = string.format(text, days(state.lengths[Calendar.WINTER]))
	end
	return text
end

-- The colour key (Ui/Theme) of `event`'s toast.
function SeasonLine.colourKey(event: Event): string
	if event.kind == "heatWave" then
		return SeasonLine.HEAT_WAVE_COLOUR
	end
	return SeasonLine.COLOURS[event.season]
end

-- The stinger (a Shared/Sounds event name) of `event`'s toast.
function SeasonLine.sound(event: Event): string
	if event.kind == "heatWave" then
		return SeasonLine.HEAT_WAVE_SOUND
	end
	return SeasonLine.SOUNDS[event.season]
end

return SeasonLine
