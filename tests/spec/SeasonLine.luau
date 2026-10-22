--[[
	What the season clock says and when its toasts come (client Ui/SeasonLine, pure): the caption
	("WINTER · 3 DAYS LEFT", "LAST DAY OF AUTUMN", "HEAT WAVE" in Warn on a heat wave's day until its
	heat is over, the name alone while the calendar is held), its width in steps; the toasts at the
	sunrise of each season's first day (every turn of the year, the year's end too) and at a heat
	wave's dawn, nothing mid-season, for a step back, a jump past MAX_STEP, the first look, /season
	set between looks or with the calendar off or held; four turns a year when looked at 4 times a
	second, a heat wave's toast for each heat wave's day; their texts (Winter's length), colours,
	stingers (Shared/Sounds' client events) and widths (no wider than the blood moon's widest, which
	the HUD's layout is tested with).
]]

return function(t, shared, require, _server, client)
	local Calendar = require(shared.Seasons.Calendar)
	local Config = require(shared.Config)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local Sounds = require(shared.Sounds)
	local SeasonLine = require(client.Ui.SeasonLine)
	local SurvivorLine = require(client.Ui.SurvivorLine)
	local Theme = require(client.Ui.Theme)

	local DAY = 24000

	local function state(lock: number?, lengths: { number }?): Calendar.State
		local s = Calendar.newState()
		s.enabled = true
		s.lock = lock
		if lengths then
			s.lengths = lengths
		end
		return s
	end

	-- A world seed whose first summer (days 24..31) has a heat wave, and that day.
	local SEED, WAVE_DAY = 0, -1
	for seed = 1, 200 do
		for day = 24, 31 do
			if SeasonClimate.isHeatWave(day, seed, state()) then
				SEED, WAVE_DAY = seed, day
				break
			end
		end
		if WAVE_DAY >= 0 then
			break
		end
	end

	t.test("season line: the caption", function()
		local s = state()
		local function caption(dayTime: number, heat: boolean?, held: boolean?): (string, string)
			return SeasonLine.caption(Calendar.position(dayTime, s), heat == true, held == true)
		end
		local text, key = caption(13 * DAY)
		t.eq(text, "WINTER · 3 DAYS LEFT", "the design's example (Winter's sixth day)")
		t.eq(key, "SeasonWinter")
		t.eq((caption(0)), "AUTUMN · 8 DAYS LEFT", "a season's first day: all of it left")
		t.eq((caption(6 * DAY + 23999)), "AUTUMN · 2 DAYS LEFT")
		text, key = caption(7 * DAY)
		t.eq(text, "LAST DAY OF AUTUMN")
		t.eq(key, "SeasonAutumn")
		t.eq((caption(31 * DAY)), "LAST DAY OF SUMMER")
		text, key = caption(26 * DAY, true)
		t.ok(text == "HEAT WAVE" and key == "Warn", "a heat wave, in Warn")
		t.eq((caption(13 * DAY, false, true)), "WINTER", "held: no days run out")
		-- A one-day season: always its last day.
		local short = state(nil, { 1, 1, 1, 1 })
		t.eq((SeasonLine.caption(Calendar.position(1 * DAY, short), false, false)), "LAST DAY OF WINTER")
		-- Every caption a calendar can show is listed (the HUD's layout takes the widest).
		local listed: { [string]: boolean } = {}
		for _, line in SeasonLine.captions(s) do
			listed[line] = true
		end
		for day = 0, 31 do
			t.ok(listed[(caption(day * DAY))] or false, `day {day}'s caption listed`)
		end
		t.ok(listed["HEAT WAVE"] and listed["WINTER"], "the heat wave and held")
		local function measure(line: string): number
			return (utf8.len(line) :: number) * 5
		end
		t.eq(SeasonLine.captionWidth("WINTER · 3 DAYS LEFT", measure), 104, "20 characters and the outline, in 8s")
		t.eq(SeasonLine.captionWidth("HEAT WAVE", measure) % SeasonLine.WIDTH_STEP, 0)
	end)

	t.test("season line: a heat wave's caption from its dawn until its heat is over", function()
		t.ok(WAVE_DAY >= 24, `a seed with a heat wave ({SEED}, day {WAVE_DAY})`)
		local s = state()
		local wave = Config.Seasons.Climate.HeatWave
		local base = WAVE_DAY * DAY
		t.ok(SeasonLine.heatWaveShown(base, SEED, s), "from dawn")
		t.ok(SeasonLine.heatWaveShown(base + wave.From + 100, SEED, s), "in the heat")
		t.ok(SeasonLine.heatWaveShown(base + wave.To + wave.Ramp - 1, SEED, s), "while it fades")
		t.ok(not SeasonLine.heatWaveShown(base + wave.To + wave.Ramp, SEED, s), "over")
		for day = 0, 31 do
			local shown = SeasonLine.heatWaveShown(day * DAY + 6000, SEED, s)
			t.eq(shown, SeasonClimate.isHeatWave(day, SEED, s), `day {day} as the climate's`)
		end
		local off = Calendar.newState()
		off.enabled = false
		t.ok(not SeasonLine.heatWaveShown(base + 6000, SEED, off), "never with the calendar off")
		-- (Held on a heat wave's day, every day is one: as the climate has it.)
		t.ok(SeasonLine.heatWaveShown(100 * DAY + 6000, SEED, state(WAVE_DAY)), "held")
	end)

	t.test("season line: a toast at the sunrise of each season's first day, and none mid-season", function()
		local s = state()
		local function events(before: number?, now: number, st: Calendar.State?): { SeasonLine.Event }
			return SeasonLine.events(before, now, SEED, st or s)
		end
		for season, day in { 0, 8, 16, 24 } do
			local at = (32 + day) * DAY
			local list = events(at - 5, at)
			local turned = list[1]
			t.ok(turned ~= nil and turned.kind == "season" and turned.season == season, `season {season} at sunrise`)
			t.eq(#events(at, at + 5), 0, "not again just after")
		end
		t.eq(#events(4 * DAY - 5, 4 * DAY), 0, "a day mid autumn")
		t.eq(#events(4 * DAY + 6000, 4 * DAY + 6005), 0, "noon")
		-- Nothing for the first look, a step back, a jump.
		t.eq(#events(nil, 8 * DAY), 0, "the first look")
		t.eq(#events(8 * DAY + 5, 8 * DAY - 5), 0, "a step back")
		t.eq(#events(8 * DAY - 601, 8 * DAY), 0, "a jump past MAX_STEP")
		t.eq(#events(8 * DAY - 600, 8 * DAY), 1, "MAX_STEP itself is watched")
		-- Off, held, /season set between looks (both ends read with the same calendar).
		local off = Calendar.newState()
		off.enabled = false
		t.eq(#events(8 * DAY - 5, 8 * DAY, off), 0, "off")
		t.eq(#events(8 * DAY - 5, 8 * DAY, state(3)), 0, "held")
		local set = state()
		set.offset = 7
		t.eq(#events(4 * DAY + 100, 4 * DAY + 105, set), 0, "set to Winter between looks: no toast")
		-- A heat wave's dawn.
		local list = events(WAVE_DAY * DAY - 5, WAVE_DAY * DAY)
		local found = false
		for _, event in list do
			found = found or event.kind == "heatWave"
		end
		t.ok(found, "a heat wave's dawn")
	end)

	t.test("season line: a year looked at 4 times a second, four turns and every heat wave", function()
		local s = state()
		local turns: { number } = {}
		local waves = 0
		local before: number? = nil
		for now = 0, 32 * DAY + 10, 5 do
			for _, event in SeasonLine.events(before, now, SEED, s) do
				if event.kind == "season" then
					table.insert(turns, event.season)
				else
					waves += 1
				end
			end
			before = now
		end
		t.eq(table.concat(turns, ","), "2,3,4,1", "Winter, Spring, Summer, then Autumn again")
		local expected = 0
		for day = 1, 32 do
			if SeasonClimate.isHeatWave(day, SEED, s) then
				expected += 1
			end
		end
		t.ok(expected >= 1, "the seed has heat waves")
		t.eq(waves, expected, "a toast each heat wave's dawn")
		-- Held: no turn, a heat wave's toast every dawn of a held heat wave's day.
		local held = state(WAVE_DAY)
		local count, last = 0, nil :: number?
		for now = 40 * DAY, 43 * DAY + 10, 5 do
			for _, event in SeasonLine.events(last, now, SEED, held) do
				t.eq(event.kind, "heatWave", "held: no turns")
				count += 1
			end
			last = now
		end
		t.eq(count, 3, "three dawns")
	end)

	t.test("season line: the toasts' texts, colours, stingers and widths", function()
		local s = state()
		local function text(kind: string, season: number, st: Calendar.State?): string
			return SeasonLine.toastText({ kind = kind :: any, season = season }, st or s)
		end
		t.eq(text("season", 1), "Autumn · the leaves turn")
		t.eq(text("season", 2), "Winter has come · 8 days")
		t.eq(text("season", 2, state(nil, { 8, 1, 8, 8 })), "Winter has come · 1 day")
		t.eq(text("season", 3), "Spring · the thaw begins")
		t.eq(text("season", 4), "Summer · heat waves ahead")
		t.eq(text("heatWave", 4), SeasonLine.HEAT_WAVE_TOAST)
		local function measure(line: string): number
			return (utf8.len(line) :: number) * 8
		end
		local widest = 0
		for _, line in SurvivorLine.TOASTS do
			widest = math.max(widest, SurvivorLine.toastWidth(measure(line)))
		end
		for season = 1, 4 do
			local event: SeasonLine.Event = { kind = "season", season = season }
			local key = SeasonLine.colourKey(event)
			t.eq(key, Theme.Season[season], `season {season}'s colour`)
			t.ok(Theme.Colour[key] ~= nil)
			local sound = Sounds.get(SeasonLine.sound(event))
			t.ok(sound ~= nil and sound.side == "client", `{SeasonLine.sound(event)}: a client event`)
			local width = SurvivorLine.toastWidth(measure(SeasonLine.toastText(event, s)))
			t.ok(width <= widest, `season {season}'s toast ({width}) no wider than the blood moon's ({widest})`)
		end
		local wave: SeasonLine.Event = { kind = "heatWave", season = 4 }
		t.eq(SeasonLine.colourKey(wave), "Warn")
		t.eq(SeasonLine.sound(wave), "ambient.season.heat_wave")
		t.ok((Sounds.get(SeasonLine.sound(wave)) :: any).side == "client")
		t.ok(SurvivorLine.toastWidth(measure(SeasonLine.HEAT_WAVE_TOAST)) <= widest, "the heat wave's toast")
		t.eq(SeasonLine.sound({ kind = "season", season = 2 }), "ambient.season.winter")
	end)
end
