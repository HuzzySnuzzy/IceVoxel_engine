--[[
	The season clock's face (client Ui/SeasonClock, pure): 32 year ticks and 16 day ticks as radial
	bars inside the dial, on their rings, turned to their angles; the year ring's seasons in
	proportion to the lengths (a tick a day at 8 days a season); the day ring's segments from the
	warped sun (autumn and spring 8 day, 2 dusk, 6 night; winter 6 / 2 / 8; summer 10 / 2 / 4; with
	the seasons off as autumn's), so winter's long nights show; the hand (noon at the top, midnight
	at the bottom) and the year marker (Autumn's first day at the top); the day number's size in
	both dials; the recolouring signature; and Ui/Theme's season clock colours (every key it and
	Ui/SeasonLine name exists, 0..255 with a transparency).
]]

return function(t, shared, require, _server, client)
	local Calendar = require(shared.Seasons.Calendar)
	local DayCycle = require(shared.DayCycle)
	local HudLayout = require(client.Ui.HudLayout)
	local SeasonClock = require(client.Ui.SeasonClock)
	local SeasonLine = require(client.Ui.SeasonLine)
	local Theme = require(client.Ui.Theme)

	local DAY = 24000

	local function state(lengths: { number }?): Calendar.State
		local s = Calendar.newState()
		s.enabled = true
		if lengths then
			s.lengths = lengths
		end
		return s
	end

	-- Runs `fn` with `s` as the calendar's module state (the sun's warp), then puts the old one back.
	local function with(s: Calendar.State, fn: () -> ())
		local before = Calendar.state()
		Calendar.setState(s)
		local ok, err = pcall(fn)
		Calendar.setState(before)
		if not ok then
			error(err, 0)
		end
	end

	t.test("season clock: the ticks are radial bars on their rings, inside the dial", function()
		local function check(bars: { SeasonClock.Bar }, count: number, ring: any, angleOf: (number) -> number)
			t.eq(#bars, count)
			local middle = (ring.inner + ring.outer) / 4
			for i, bar in bars do
				local angle = angleOf(i)
				t.near(bar.rotation, angle, 1e-9, `tick {i}: turned to its angle`)
				local dx, dy = bar.x - 0.5, bar.y - 0.5
				t.near(math.sqrt(dx * dx + dy * dy), middle, 1e-9, `tick {i}: on its ring`)
				-- (Its direction from the centre is its angle: clockwise from the top.)
				t.near(
					math.atan2(dx, -dy) % (2 * math.pi),
					math.rad(angle) % (2 * math.pi),
					1e-6,
					`tick {i}: direction`
				)
				t.near(bar.h, (ring.outer - ring.inner) / 2, 1e-9, `tick {i}: spans the ring`)
				-- (Every corner of the turned bar inside the dial.)
				local reach = math.sqrt(bar.w * bar.w + bar.h * bar.h) / 2
				t.ok(
					bar.x - reach >= 0 and bar.x + reach <= 1 and bar.y - reach >= 0 and bar.y + reach <= 1,
					`tick {i} inside the dial`
				)
			end
		end
		check(SeasonClock.yearTicks(), SeasonClock.YEAR_TICKS, SeasonClock.YEAR_RING, SeasonClock.yearTickAngle)
		check(SeasonClock.dayTicks(), SeasonClock.DAY_TICKS, SeasonClock.DAY_RING, SeasonClock.segmentAngle)
		t.eq(SeasonClock.YEAR_TICKS, 32)
		t.eq(SeasonClock.DAY_TICKS, 16)
		t.eq(SeasonClock.SEGMENT, 1500, "Don't Starve's 16 segments of the day")
		-- The rings apart, the day number's disc inside the day ring, the marker and hand inside.
		t.ok(SeasonClock.DAY_RING.outer < SeasonClock.YEAR_RING.inner, "the day ring inside the year ring")
		t.ok(SeasonClock.CENTRE <= SeasonClock.DAY_RING.inner, "the centre's disc inside the day ring")
		for angle = 0, 359, 7 do
			for _, bar in { SeasonClock.hand(angle), SeasonClock.marker(angle) } do
				local reach = math.sqrt(bar.w * bar.w + bar.h * bar.h) / 2
				local dx, dy = bar.x - 0.5, bar.y - 0.5
				t.ok(math.sqrt(dx * dx + dy * dy) + reach <= 0.5 + 1e-9, `pointer at {angle} inside the dial`)
			end
		end
		-- (The year ticks a gap apart: narrower than their spacing at the inner radius.)
		local spacing = 2 * math.pi * SeasonClock.YEAR_RING.inner / 2 / SeasonClock.YEAR_TICKS
		t.ok(SeasonClock.YEAR_RING.width < spacing, "year ticks apart")
		local daySpacing = 2 * math.pi * SeasonClock.DAY_RING.inner / 2 / SeasonClock.DAY_TICKS
		t.ok(SeasonClock.DAY_RING.width < daySpacing, "day ticks apart")
	end)

	t.test("season clock: the year ring's seasons follow the lengths", function()
		local seasons = SeasonClock.yearSeasons({ 8, 8, 8, 8 })
		for i = 1, 32 do
			t.eq(seasons[i], (i - 1) // 8 + 1, `tick {i}: a day a tick`)
		end
		local counts = { 0, 0, 0, 0 }
		for i, season in SeasonClock.yearSeasons({ 4, 8, 12, 8 }) do
			counts[season] += 1
			if i > 1 then
				t.ok(season >= SeasonClock.yearSeasons({ 4, 8, 12, 8 })[i - 1], "in order around the ring")
			end
		end
		t.ok(counts[1] == 4 and counts[2] == 8 and counts[3] == 12 and counts[4] == 8, "in proportion (a 32 day year)")
		counts = { 0, 0, 0, 0 }
		for _, season in SeasonClock.yearSeasons({ 20, 15, 20, 15 }) do
			counts[season] += 1
		end
		t.ok(counts[1] == 9 and counts[2] == 7 and counts[3] == 9 and counts[4] == 7, "Don't Starve's 70 day year")
		-- (A one-day season still shows.)
		counts = { 0, 0, 0, 0 }
		for _, season in SeasonClock.yearSeasons({ 2, 2, 2, 2 }) do
			counts[season] += 1
		end
		t.ok(counts[1] == 8 and counts[4] == 8, "short seasons: still a quarter each")
	end)

	-- The day ring's counts (day, dusk, night) on calendar day `day` with `s`.
	local function split(s: Calendar.State, day: number): (number, number, number)
		local counts = { day = 0, dusk = 0, night = 0 }
		with(s, function()
			for _, segment in SeasonClock.daySegments(day * DAY + 300) do
				counts[segment] += 1
			end
		end)
		return counts.day, counts.dusk, counts.night
	end

	t.test("season clock: the day ring shows winter's long nights and summer's long days", function()
		local s = state()
		local function check(day: number, expect: { number }, name: string)
			local d, u, n = split(s, day)
			t.ok(d == expect[1] and u == expect[2] and n == expect[3], `{name}: {d} day, {u} dusk, {n} night`)
		end
		check(4, { 8, 2, 6 }, "mid autumn")
		check(12, { 6, 2, 8 }, "mid winter")
		check(20, { 8, 2, 6 }, "mid spring")
		check(28, { 10, 2, 4 }, "mid summer")
		-- With the seasons off: the sun's own day, as autumn's.
		local off = Calendar.newState()
		off.enabled = false
		local d, u, n = split(off, 12)
		t.ok(d == 8 and u == 2 and n == 6, `off: {d} / {u} / {n}`)
		-- Every day of the year: 16 segments, the night never shorter in winter than in summer.
		for day = 0, 31 do
			local dd, du, dn = split(s, day)
			t.eq(dd + du + dn, 16, `day {day}: 16 segments`)
		end
		local _, _, winterNight = split(s, 12)
		local _, _, summerNight = split(s, 28)
		t.ok(winterNight > summerNight, "winter's nights are longer")
		-- Day first (sunrise is tick 0), then dusk, night, and dusk before dawn.
		with(s, function()
			local segments = SeasonClock.daySegments(4 * DAY)
			t.eq(segments[1], "day", "after sunrise")
			t.eq(segments[5], "day", "noon")
			t.eq(segments[12], "night", "midnight")
			t.eq(SeasonClock.segmentAt(4 * DAY + 6000), "day")
			t.eq(SeasonClock.segmentAt(4 * DAY + 18000), "night")
		end)
	end)

	t.test("season clock: the hand, the year marker and the day number", function()
		t.near(SeasonClock.handAngle(6000), 0, 1e-9, "noon at the top")
		t.near(SeasonClock.handAngle(12000), 90, 1e-9, "evening on the right")
		t.near(SeasonClock.handAngle(18000), 180, 1e-9, "midnight at the bottom")
		t.near(SeasonClock.handAngle(0), 270, 1e-9, "sunrise on the left")
		t.near(SeasonClock.handAngle(5 * DAY + 6000), 0, 1e-9, "any day")
		-- It turns steadily (4 Hz looks: under a degree each).
		local last = SeasonClock.handAngle(0)
		for ticks = 5, DAY, 5 do
			local angle = SeasonClock.handAngle(ticks)
			local step = (angle - last) % 360
			t.ok(step > 0 and step < 1, `turns on at {ticks}`)
			last = angle
		end
		-- The hand's segment: its angle within the segment's.
		for j = 1, 16 do
			local middle = (j - 0.5) * SeasonClock.SEGMENT
			t.near(SeasonClock.handAngle(middle), SeasonClock.segmentAngle(j) % 360, 1e-9, `segment {j}`)
		end
		local s = state()
		t.near(SeasonClock.yearAngle(Calendar.position(0, s)), 0, 1e-9, "Autumn's first day at the top")
		t.near(SeasonClock.yearAngle(Calendar.position(8 * DAY, s)), 90, 1e-9, "Winter a quarter round")
		t.near(SeasonClock.yearAngle(Calendar.position(16 * DAY, s)), 180, 1e-9, "Spring")
		t.near(SeasonClock.yearAngle(Calendar.position(32 * DAY, s)), 0, 1e-9, "a year round")
		-- The day number: DayCycle.day + 1, smaller when it would not fit the centre.
		local text, size = SeasonClock.dayText(1000, HudLayout.CLOCK)
		t.ok(text == "1" and size == 8, "day 1")
		text, size = SeasonClock.dayText(41 * DAY, HudLayout.CLOCK)
		t.ok(text == "42" and size == 8, "two digits at 8")
		text, size = SeasonClock.dayText(99 * DAY, HudLayout.CLOCK)
		t.ok(text == "100" and size == 6, "three digits at 6")
		text, size = SeasonClock.dayText(41 * DAY, HudLayout.CLOCK_SMALL)
		t.ok(size == 8, "two digits fit the small dial")
		text, size = SeasonClock.dayText(99 * DAY, HudLayout.CLOCK_SMALL)
		t.ok(size == 4, "three digits in the small dial")
		for _, dial in { HudLayout.CLOCK, HudLayout.CLOCK_SMALL } do
			for _, day in { 0, 9, 99, 999 } do
				local digits, at = SeasonClock.dayText(day * DAY, dial)
				t.ok(#digits * at <= dial * SeasonClock.CENTRE or at == 4, `{digits} fits the {dial} dial`)
			end
		end
		t.eq(DayCycle.day(41 * DAY) + 1, 42)
	end)

	t.test("season clock: the ticks are recoloured only when what they show changes", function()
		local s = state()
		with(s, function()
			local function at(dayTime: number): string
				local p = Calendar.position(dayTime, s)
				return SeasonClock.signature(p.season, s.lengths, SeasonClock.daySegments(dayTime))
			end
			t.eq(at(4 * DAY + 100), at(4 * DAY + 23000), "the same all day")
			t.eq(at(4 * DAY), at(5 * DAY), "and from day to day mid season")
			t.ok(at(7 * DAY) ~= at(8 * DAY), "the season turns")
			t.ok(at(4 * DAY) ~= at(12 * DAY), "the day's split changes")
			t.ok(
				SeasonClock.signature(1, { 8, 8, 8, 8 }, SeasonClock.daySegments(0))
					~= SeasonClock.signature(1, { 8, 9, 8, 8 }, SeasonClock.daySegments(0)),
				"the lengths change"
			)
		end)
	end)

	t.test("season clock: Ui/Theme's colours", function()
		local function isRgba(colour: any): boolean
			if type(colour) ~= "table" then
				return false
			end
			for _, key in { "r", "g", "b" } do
				local v = colour[key]
				if type(v) ~= "number" or v < 0 or v > 255 or v ~= math.floor(v) then
					return false
				end
			end
			return type(colour.t) == "number" and colour.t >= 0 and colour.t <= 1
		end
		t.eq(#Theme.Season, 4)
		for season = 1, 4 do
			local key = Theme.Season[season]
			t.ok(isRgba(Theme.Colour[key]), `{key}`)
			t.eq(SeasonLine.COLOURS[season], key, "Ui/SeasonLine's keys are Theme's")
			t.eq(Theme.Colour[key].t, 0, `{key} opaque`)
		end
		for _, key in { "ClockFace", "ClockDay", "ClockDusk", "ClockNight", "ClockHand", "ClockMarker", "Warn", "Text" } do
			t.ok(isRgba(Theme.Colour[key]), key)
		end
		t.eq(SeasonLine.HEAT_WAVE_COLOUR, "Warn")
		t.ok(Theme.CLOCK_DIM_T > 0 and Theme.CLOCK_DIM_T < 1, "the other seasons dimmer, still there")
		-- The seasons and the segments told apart (no two the same colour).
		local seen: { [string]: string } = {}
		for _, key in
			{ "SeasonAutumn", "SeasonWinter", "SeasonSpring", "SeasonSummer", "ClockDay", "ClockDusk", "ClockNight" }
		do
			local c = Theme.Colour[key]
			local id = `{c.r},{c.g},{c.b}`
			t.ok(seen[id] == nil, `{key} differs from {seen[id]}`)
			seen[id] = key
		end
		-- Winter is the coolest of the seasons, Autumn the warmest red.
		local winter, autumn = Theme.Colour.SeasonWinter, Theme.Colour.SeasonAutumn
		t.ok(winter.b > winter.r and autumn.r > autumn.b, "ice-blue winter, orange autumn")
	end)
end
