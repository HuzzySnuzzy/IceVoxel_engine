--[[
	The HUD's shared corner (client Ui/HudLayout): over phones (568 x 320, 667 x 375, a notched
	844 x 390), tablets (1024 x 768), Studio's 1280 x 660, desktops (1366 x 768, 1920 x 1080,
	2560 x 1440) and 4K, times every GUI Scale choice the screen offers, the minimap on and off,
	touch on and off, the toasts and the saving icon showing or not and a few sets of effect icons:
	everything placed stays inside the safe area below the top bar; the minimap, its coordinates
	line, the zombie apocalypse's day line (in its three places: under the coordinates line, under
	the Map button, in the corner; its real texts, a blood moon's warning wrapped onto a second
	row where one row doesn't fit, and always placed) and its notice toasts (as wide as their
	texts), the Map button, the toasts, the effect icons, the saving icon, the touch buttons and
	the HUD's canvas never overlap (also while its rows are raised over the mana stars); WAILA's
	reserve covers the minimap column and the day line; the toasts start under the minimap's
	scaled bottom (under the day line when it shows). Named regressions: on a 667 x 375 phone the
	effect icons ran past the bottom of the screen and the saving icon sat on the minimap (the
	corner was pinned to a 192 pixel minimap and raised by a fixed 150 GUI pixels); on an iPad and
	a 1024 x 768 window at their Auto GUI scale the day line vanished the day before a blood moon
	and on its day until it rose (one row of 360 GUI pixels didn't fit and nothing took its place),
	and the blood moon's toasts ran past the screen's edge (a 160 pixel toast for 208 and 216
	pixels of text).
]]

return function(t, _shared, require, _server, client)
	local GuiScale = require(client.Ui.GuiScale)
	local HudLayout = require(client.Ui.HudLayout)
	local SurvivorLine = require(client.Ui.SurvivorLine)

	type Insets = HudLayout.Insets
	type Rect = HudLayout.Rect

	local function insets(left: number, top: number, right: number, bottom: number, bar: number): Insets
		return { left = left, top = top, right = right, bottom = bottom, bar = bar }
	end

	-- width, height, safe insets (the notched phone's), Roblox's top bar.
	local SCREENS = {
		{ 568, 320, insets(0, 0, 0, 0, 58) },
		{ 667, 375, insets(0, 0, 0, 0, 58) },
		{ 667, 375, insets(0, 0, 0, 0, 36) },
		{ 844, 390, insets(47, 0, 47, 21, 58) },
		{ 1024, 768, insets(0, 0, 0, 0, 58) },
		{ 1280, 660, insets(0, 0, 0, 0, 58) },
		{ 1366, 768, insets(0, 0, 0, 0, 58) },
		{ 1920, 1080, insets(0, 0, 0, 0, 58) },
		{ 2560, 1440, insets(0, 0, 0, 0, 58) },
		{ 3840, 2160, insets(0, 0, 0, 0, 58) },
	}
	-- The coordinates line's text: the map's width, and "1234, 64, -5678  1:4" in the pixel font.
	local COORDS = { 56, 160 }
	-- Effect icons: none, one, three beneficial over two harmful, a full row of eight.
	local EFFECTS = {
		HudLayout.effectsSize(0, 0),
		HudLayout.effectsSize(1, 1),
		HudLayout.effectsSize(3, 2),
		HudLayout.effectsSize(8, 2),
	}
	-- "World saved": none, Minecraft's width, a long line.
	local SAVES: { number | false } = { false, 160, 240 }

	local function describe(input: HudLayout.Input): string
		return `{input.width} x {input.height} bar {input.insets.bar} scale {input.scale} touch {input.touch} minimap {input.minimap} coords {input.coordsWidth} music {input.music} save {input.save} under {input.saveUnder} saving {input.saving} effects {if input.effects
			then `{input.effects.w}x{input.effects.h}`
			else "none"}`
	end

	-- Every combination, `check(input, layout)` returning a problem or nil; at most a few reported.
	local function sweep(check: (HudLayout.Input, HudLayout.Layout) -> string?): (number, { string })
		local count = 0
		local problems: { string } = {}
		for _, screen in SCREENS do
			local w, h, inset = screen[1], screen[2], screen[3]
			for _, touch in { false, true } do
				for _, choice in GuiScale.choices(w, h, touch) do
					local scale = GuiScale.base(w, h, touch, choice)
					for _, minimap in { true, false } do
						for _, coords in COORDS do
							for _, music in { false, true } do
								for _, save in SAVES do
									for _, under in { false, true } do
										for _, saving in { false, true } do
											for _, effects in EFFECTS do
												local input: HudLayout.Input = {
													width = w,
													height = h,
													insets = inset,
													scale = scale,
													touch = touch,
													minimap = minimap,
													coordsWidth = coords,
													music = music,
													save = if save then save else nil,
													saveUnder = under,
													effects = effects,
													saving = saving,
													debugRight = nil,
													buttons = nil,
												}
												count += 1
												local problem = check(input, HudLayout.compute(input))
												if problem and #problems < 5 then
													table.insert(problems, `{describe(input)}: {problem}`)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		return count, problems
	end

	-- The rectangles that show, by name (the toasts only while they show).
	local function shown(input: HudLayout.Input, layout: HudLayout.Layout): { [string]: Rect }
		local list: { [string]: Rect } = {}
		list.minimap = layout.minimap :: any
		list.coords = layout.coords :: any
		list.mapButton = layout.mapButton :: any
		if input.music then
			list.music = layout.music :: any
		end
		list.save = layout.save :: any
		list.effects = layout.effects :: any
		list.saving = layout.saving :: any
		return list
	end

	t.test("hud layout: everything inside the safe area, below the top bar, nothing overlapping", function()
		local count, problems = sweep(function(input, layout)
			local safe = HudLayout.safeArea(input.width, input.height, input.insets)
			local rects = shown(input, layout)
			for name, r in rects do
				if not HudLayout.inside(r, safe) then
					return `{name} leaves the safe area`
				end
			end
			for name, r in rects do
				for other, q in rects do
					if name < other and HudLayout.overlaps(r, q) then
						return `{name} overlaps {other}`
					end
				end
				for _, button in layout.buttons do
					if HudLayout.overlaps(r, button) then
						return `{name} covers a touch button`
					end
				end
				if HudLayout.overlaps(r, layout.hud) then
					return `{name} covers the HUD`
				end
			end
			return nil
		end)
		t.ok(count > 10000, `the sweep ran ({count})`)
		t.ok(#problems == 0, table.concat(problems, "\n         "))
	end)

	t.test(
		"hud layout: the column follows the scale, the toasts its scaled bottom, WAILA's reserve covers it",
		function()
			local count, problems = sweep(function(input, layout)
				local s = input.scale
				if input.minimap then
					local map, coords = layout.minimap, layout.coords
					if map == nil or coords == nil then
						return "no minimap"
					end
					if math.abs(map.w - HudLayout.MINIMAP * s) > 1e-9 or map.w ~= map.h then
						return `the minimap is {map.w} x {map.h}`
					end
					local low = layout.wailaLow
					if layout.wailaRight > map.x or low == nil or low.right > coords.x or low.right > map.x then
						return "WAILA's reserve leaves the minimap column"
					end
					if low.y > coords.y then
						return "WAILA's low reserve starts under the coordinates line"
					end
					local music = layout.music
					if music and (not input.music or music.x + music.w >= layout.area.x + layout.area.w - 0.5) then
						if music.y < coords.y + coords.h then
							return "the toast starts above the minimap's bottom"
						end
						if math.abs(music.y - (coords.y + coords.h + HudLayout.GAP * s)) > 1 then
							return "the toast does not follow the minimap's bottom"
						end
					end
				elseif input.touch then
					local button = layout.mapButton
					if button == nil then
						return "no Map button"
					end
					-- (A finger's size, whatever the scale.)
					if button.h < HudLayout.TOUCH_TARGET or button.w < 2 * HudLayout.TOUCH_TARGET then
						return `the Map button is {button.w} x {button.h}`
					end
					if layout.wailaRight > button.x then
						return "WAILA's reserve leaves the Map button"
					end
				end
				-- Typical effect icons (up to three a row) are never dropped.
				local effects = input.effects
				if effects and effects.w <= 3 * HudLayout.EFFECT_STEP and layout.effects == nil then
					return "the effect icons were dropped"
				end
				-- Toasts that show are placed.
				if input.music and layout.music == nil then
					return "Now Playing was dropped"
				end
				-- On a touch screen the effect icons (buttons) keep out of the thumbstick's zone.
				local icons = layout.effects
				if
					input.touch
					and icons
					and HudLayout.overlaps(icons, HudLayout.thumbstick(input.width, input.height))
				then
					return "the effect icons are in the thumbstick's zone"
				end
				-- The HUD's rows raised over the mana stars (10 or 20 GUI pixels) drop a toast only
				-- where it would sit on them (it then waits for room: Ui/MusicToast, SaveIndicator).
				for _, raise in { 10, 20 } do
					local raisedInput = table.clone(input)
					raisedInput.hudRaise = raise
					local raised = HudLayout.compute(raisedInput)
					if input.music and raised.music == nil then
						local music = layout.music
						if music == nil or not HudLayout.overlaps(music, raised.hud) then
							return `raised {raise}: Now Playing was dropped with room for it`
						end
					end
					if effects and effects.w <= 3 * HudLayout.EFFECT_STEP and raised.effects == nil then
						local icons2 = layout.effects
						if icons2 == nil or not HudLayout.overlaps(icons2, raised.hud) then
							return `raised {raise}: the effect icons were dropped with room for them`
						end
					end
				end
				return nil
			end)
			t.ok(count > 10000, `the sweep ran ({count})`)
			t.ok(#problems == 0, table.concat(problems, "\n         "))
		end
	)

	--[[ The zombie apocalypse's day line (Ui/SurvivorHud) and its notice toasts ]]

	-- The pixel font: 8 GUI pixels a character (tests/spec/TextWrap's Arcade).
	local function measure(text: string): number
		return (utf8.len(text) :: number) * 8
	end
	-- The day line's real texts, from "Day 5" (creative) to the longest a long world shows, as
	-- Ui/SurvivorHud measures them: { one row, wrapped }.
	local DAY_LINES: { { number | false } } = {}
	for _, line in
		{
			{ "Day 5", nil },
			{ "Day 4 · Survived 3 days", nil },
			{ "Day 3 · Survived 2 days", "Blood Moon tonight" },
			{ "Day 999 · Survived 999 days", "Blood Moon tomorrow" },
		} :: { { string? } }
	do
		local one, wrap = SurvivorLine.widths(line[1] :: string, line[2], measure)
		table.insert(DAY_LINES, { one, wrap or false })
	end
	-- The blood moon's toasts' widths, the widest of them.
	local widestToast = 0
	for _, text in SurvivorLine.TOASTS do
		widestToast = math.max(widestToast, SurvivorLine.toastWidth(measure(text)))
	end

	-- Every screen and scale with the day line showing: the minimap on and off, touch on and off,
	-- the day line's real texts, the toasts (Now Playing, "World saved", a notice of Minecraft's
	-- width and the widest blood moon's), the saving icon and effect icons. `check(input, layout)`
	-- returns a problem or nil.
	local function sweepDay(check: (HudLayout.Input, HudLayout.Layout) -> string?): (number, { string })
		local count = 0
		local problems: { string } = {}
		for _, screen in SCREENS do
			local w, h, inset = screen[1], screen[2], screen[3]
			for _, touch in { false, true } do
				for _, choice in GuiScale.choices(w, h, touch) do
					local scale = GuiScale.base(w, h, touch, choice)
					for _, minimap in { true, false } do
						for _, coords in COORDS do
							for _, dayLine in DAY_LINES do
								local dayWidth, dayWrap = dayLine[1] :: number, dayLine[2]
								for _, music in { false, true } do
									for _, save in { false, 160 } do
										for _, notice in { false, 160, widestToast } do
											for _, saving in { false, true } do
												for _, effects in { EFFECTS[1], EFFECTS[3] } do
													local input: HudLayout.Input = {
														width = w,
														height = h,
														insets = inset,
														scale = scale,
														touch = touch,
														minimap = minimap,
														coordsWidth = coords,
														music = music,
														save = if save then save else nil,
														saveUnder = false,
														effects = effects,
														saving = saving,
														debugRight = nil,
														dayLine = true,
														dayWidth = dayWidth,
														dayWrap = if dayWrap then dayWrap else nil,
														notice = if notice then notice else nil,
														buttons = nil,
													}
													count += 1
													local problem = check(input, HudLayout.compute(input))
													if problem and #problems < 5 then
														table.insert(
															problems,
															`{describe(input)} day {dayWidth}/{dayWrap} notice {input.notice}: {problem}`
														)
													end
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		return count, problems
	end

	t.test("hud layout: the day line, in all three places, inside the safe area and overlapping nothing", function()
		local count, problems = sweepDay(function(input, layout)
			local day = layout.day
			if day == nil then
				return "no day line"
			end
			local s = input.scale
			local rows = layout.dayRows
			if math.abs(day.h - HudLayout.COORDS_HEIGHT * rows * s) > 1e-9 then
				return `the day line is {day.h} tall on {rows} rows`
			end
			local width = if rows == 2 then input.dayWrap else input.dayWidth
			if width == nil or math.abs(day.w - math.max(width, HudLayout.MINIMAP) * s) > 1e-9 then
				return `the day line is {day.w} wide on {rows} rows`
			end
			-- Wrapped only where one row has no room.
			if rows == 2 then
				local single = table.clone(input)
				single.dayWrap = nil
				if HudLayout.compute(single).day ~= nil then
					return "wrapped where one row fits"
				end
			end
			local area = layout.area
			if math.abs(day.x + day.w - (area.x + area.w)) > 1 then
				return "the day line is not right aligned"
			end
			-- Its place: under the coordinates line, under the Map button, or in the corner.
			local under = layout.coords or layout.mapButton
			if input.minimap then
				local coords = layout.coords :: Rect
				if math.abs(day.y - (coords.y + coords.h + HudLayout.GAP * s)) > 1 then
					return "not under the coordinates line"
				end
			elseif input.touch then
				local button = layout.mapButton :: Rect
				if button == nil or math.abs(day.y - (button.y + button.h + HudLayout.GAP * s)) > 1 then
					return "not under the Map button"
				end
			elseif under ~= nil or math.abs(day.y - area.y) > 1 then
				return "not in the corner"
			end
			-- Everything that shows: inside, and disjoint.
			local safe = HudLayout.safeArea(input.width, input.height, input.insets)
			local rects = shown(input, layout)
			rects.day = day
			rects.notice = layout.notice :: any
			for name, r in rects do
				if not HudLayout.inside(r, safe) then
					return `{name} leaves the safe area`
				end
				for other, q in rects do
					if name < other and HudLayout.overlaps(r, q) then
						return `{name} overlaps {other}`
					end
				end
				for _, button in layout.buttons do
					if HudLayout.overlaps(r, button) then
						return `{name} covers a touch button`
					end
				end
				if HudLayout.overlaps(r, layout.hud) then
					return `{name} covers the HUD`
				end
			end
			-- The toasts' slot and the effect icons start under it (the column's bottom).
			local music = layout.music
			if music and not input.music and music.y < day.y + day.h then
				return "the toast slot starts above the day line"
			end
			local icons = layout.effects
			if icons and not layout.effectsAside and icons.y < day.y + day.h then
				return "the effect icons start above the day line"
			end
			-- WAILA keeps left of it.
			if day.x < layout.wailaRight then
				local low = layout.wailaLow
				if low == nil or low.y > day.y or low.right > day.x then
					return "WAILA's reserve leaves the day line"
				end
			end
			-- A notice showing alone is placed (on a roomy screen; among other toasts it may wait
			-- for room, as they do), under the other toasts.
			local notice = layout.notice
			if input.notice and notice == nil and input.height >= 768 and not input.music and not input.save then
				return "the notice was dropped"
			end
			if notice and input.music and layout.music and notice.x + notice.w > (layout.music :: Rect).x then
				if notice.y < (layout.music :: Rect).y + (layout.music :: Rect).h then
					return "the notice is not under Now Playing"
				end
			end
			return nil
		end)
		t.ok(count > 30000, `the sweep ran ({count})`)
		t.ok(#problems == 0, table.concat(problems, "\n         "))
	end)

	t.test("hud layout: a blood moon's warning wraps under the day line where one row doesn't fit", function()
		local one, wrap = SurvivorLine.widths("Day 2 · Survived 1 day", "Blood Moon tomorrow", measure)
		t.eq(one, 360, "one row: 44 characters and the shadow, in steps of 8")
		t.eq(wrap, 184, "wrapped: the wider of its rows")
		local bar = insets(0, 0, 0, 0, 58)
		-- (An iPad and a 1024 x 768 window at their Auto scale: 3.125 to 3.375; 1080p's 4.)
		for _, screen in
			{
				{ 1024, 768, true, 2 },
				{ 1180, 820, true, 2 },
				{ 1194, 834, true, 2 },
				{ 1024, 768, false, 2 },
				{ 1920, 1080, false, 1 },
			}
		do
			local w, h, touch, rows = screen[1], screen[2], screen[3], screen[4]
			for _, minimap in { true, false } do
				local layout = HudLayout.compute({
					width = w,
					height = h,
					insets = bar,
					scale = GuiScale.base(w, h, touch, 0),
					touch = touch,
					minimap = minimap,
					coordsWidth = 160,
					music = false,
					save = nil,
					saveUnder = false,
					effects = nil,
					saving = false,
					debugRight = nil,
					dayLine = true,
					dayWidth = one,
					dayWrap = wrap,
					buttons = nil,
				})
				local where = `{w} x {h} touch {touch} minimap {minimap}`
				t.ok(layout.day ~= nil, `{where}: the line shows`)
				t.eq(layout.dayRows, rows, `{where}: on {rows} rows`)
				-- (The toasts go under both rows.)
				local day = layout.day :: Rect
				t.ok((layout.music :: Rect).y >= day.y + day.h, `{where}: the toasts under it`)
			end
		end
	end)

	t.test("hud layout: the blood moon's toasts are as wide as their texts, and placed alone", function()
		for _, text in SurvivorLine.TOASTS do
			local width = SurvivorLine.toastWidth(measure(text))
			t.ok(width >= measure(text) + 2 * SurvivorLine.TOAST_PADDING, `"{text}" fits its toast ({width})`)
			t.ok(width >= HudLayout.TOAST_WIDTH and width % 8 == 0)
		end
		t.eq(SurvivorLine.toastWidth(measure("The Blood Moon rises")), 184)
		t.eq(widestToast, 240, "You survived the Blood Moon: 27 characters")
		local layout = HudLayout.compute({
			width = 1024,
			height = 768,
			insets = insets(0, 0, 0, 0, 58),
			scale = GuiScale.base(1024, 768, true, 0),
			touch = true,
			minimap = true,
			coordsWidth = 160,
			music = false,
			save = nil,
			saveUnder = false,
			effects = nil,
			saving = false,
			debugRight = nil,
			dayLine = true,
			dayWidth = 192,
			notice = widestToast,
			buttons = nil,
		})
		local notice = layout.notice :: Rect
		t.eq(notice.w, widestToast * layout.scale, "the whole toast")
		t.ok(notice.x + notice.w <= layout.area.x + layout.area.w + 0.5, "inside the screen's edge")
	end)

	t.test("hud layout: the day line's three places on a desktop and a phone, the toasts under it", function()
		local function input(overrides: { [string]: any }): HudLayout.Input
			local base: HudLayout.Input = {
				width = 1920,
				height = 1080,
				insets = insets(0, 0, 0, 0, 58),
				scale = 4,
				touch = false,
				minimap = true,
				coordsWidth = 160,
				music = false,
				save = nil,
				saveUnder = false,
				effects = nil,
				saving = false,
				debugRight = nil,
				dayLine = true,
				dayWidth = 120,
				buttons = nil,
			}
			for key, value in overrides do
				(base :: any)[key] = value
			end
			return base
		end
		-- With the minimap: under the coordinates line; the toast slot under the day line.
		local desk = HudLayout.compute(input({}))
		local coords, day = desk.coords :: Rect, desk.day :: Rect
		t.eq(day.y, coords.y + coords.h + 8)
		t.eq(day.h, 40, "the coordinates line's height at scale 4")
		t.eq(day.w, 480, "120 GUI pixels of text")
		t.eq((desk.music :: Rect).y, day.y + day.h + 8, "slot 1 under the day line")
		local without = HudLayout.compute(input({ dayLine = false }))
		t.eq(without.day, nil, "no day line when it doesn't show")
		t.eq((without.music :: Rect).y, coords.y + coords.h + 8, "the slot as before")
		-- Neither minimap nor touch: in the corner, the toasts under it.
		local corner = HudLayout.compute(input({ minimap = false }))
		local alone = corner.day :: Rect
		t.eq(alone.y, 58 + 16, "the area's top")
		t.eq(alone.x + alone.w, 1920 - 16, "right aligned")
		t.eq((corner.music :: Rect).y, alone.y + alone.h + 8)
		t.eq(corner.wailaRight, alone.x - 8, "WAILA keeps left of it")
		-- A touch screen with the minimap off: under the Map button.
		local touch = HudLayout.compute(input({
			width = 667,
			height = 375,
			scale = GuiScale.base(667, 375, true, 0),
			touch = true,
			minimap = false,
		}))
		local button, under = touch.mapButton :: Rect, touch.day :: Rect
		t.eq(under.y, button.y + button.h + 2 * touch.scale)
		t.ok(under.x + under.w <= touch.area.x + touch.area.w + 0.5, "right aligned")
		-- A notice toast goes under the toasts that show; beside them when the HUD is in the way.
		local both = HudLayout.compute(input({ save = 160, notice = 160 }))
		local save, notice = both.save :: Rect, both.notice :: Rect
		t.eq(notice.y, save.y + save.h + 8, "under World saved")
		local three = HudLayout.compute(input({ music = true, save = 160, notice = 160 }))
		local beside = three.notice :: Rect
		t.eq(beside.y, (three.music :: Rect).y, "a third toast would reach the HUD: beside slot 1")
		t.ok(beside.x + beside.w <= (three.music :: Rect).x, "left of it")
		local first = HudLayout.compute(input({ notice = 200 }))
		t.eq((first.notice :: Rect).y, (first.music :: Rect).y, "slot 1 when no toast shows")
		t.eq((first.notice :: Rect).w, 800, "as wide as its text")
		local icons = HudLayout.compute(input({ notice = 160, effects = HudLayout.effectsSize(2, 1) }))
		t.eq((icons.effects :: Rect).y, (icons.notice :: Rect).y + 128 + 8, "the effect icons under the notice")
	end)

	local function phone(overrides: { [string]: any }): HudLayout.Input
		local input: HudLayout.Input = {
			width = 667,
			height = 375,
			insets = insets(0, 0, 0, 0, 58),
			scale = GuiScale.base(667, 375, true, 0),
			touch = true,
			minimap = true,
			coordsWidth = 160,
			music = false,
			save = nil,
			saveUnder = false,
			effects = HudLayout.effectsSize(3, 2),
			saving = false,
			debugRight = nil,
			buttons = nil,
		}
		for key, value in overrides do
			(input :: any)[key] = value
		end
		return input
	end

	t.test("hud layout: 667 x 375, the effect icons stay on the screen with a toast showing", function()
		local input = phone({ music = true })
		t.eq(input.scale, 1.5, "the phone's Auto")
		local layout = HudLayout.compute(input)
		local effects = layout.effects
		t.ok(effects ~= nil, "shown")
		if effects then
			t.ok(effects.y + effects.h <= 375, `the icons end at {effects.y + effects.h} (they ran to 422)`)
			local jump = HudLayout.jumpButton(667, 375, input.insets)
			t.ok(not HudLayout.overlaps(effects, jump), "clear of the jump button")
			t.ok(layout.effectsAside, "beside the minimap column: under the toast they would reach the jump button")
		end
		-- Without a toast they take its slot, under the coordinates line.
		local alone = HudLayout.compute(phone({}))
		local icons, coords = alone.effects, alone.coords
		t.ok(icons ~= nil and coords ~= nil, "shown")
		if icons and coords then
			t.ok(icons.y >= coords.y + coords.h, "under the minimap column")
			t.ok(not alone.effectsAside, "in the toast's slot")
		end
	end)

	t.test("hud layout: the saving icon sits above the jump button, never on the minimap", function()
		-- (On the tablet the HUD's "..." button is under it too: it goes above both.)
		for _, case in { { 667, 375, true }, { 568, 320, true }, { 1024, 768, false } } do
			local w, h, close = case[1], case[2], case[3]
			local input = phone({ width = w, height = h, scale = GuiScale.base(w, h, true, 0), saving = true })
			local layout = HudLayout.compute(input)
			local icon, map = layout.saving, layout.minimap
			t.ok(icon ~= nil and map ~= nil, `{w} x {h}: shown`)
			if icon and map then
				t.ok(not HudLayout.overlaps(icon, map), `{w} x {h}: off the minimap`)
				local jump = HudLayout.jumpButton(w, h, input.insets)
				t.ok(not HudLayout.overlaps(icon, jump), `{w} x {h}: off the jump button`)
				t.ok(icon.y + icon.h <= jump.y, `{w} x {h}: above the jump button`)
				t.ok(not HudLayout.overlaps(icon, layout.hud), `{w} x {h}: off the HUD`)
				if close then
					t.ok(icon.y + icon.h >= jump.y - 2 * HudLayout.GAP * input.scale, `{w} x {h}: right above it`)
				end
			end
		end
		-- On a desktop it keeps the bottom right corner.
		local desk = HudLayout.compute(phone({ width = 1920, height = 1080, scale = 4, touch = false, saving = true }))
		local icon = desk.saving
		t.ok(icon ~= nil, "desktop")
		if icon then
			t.eq(icon.x + icon.w, 1920 - HudLayout.MARGIN * 4)
			t.eq(icon.y + icon.h, 1080 - HudLayout.MARGIN * 4)
		end
		-- The live buttons count, whatever their size (Roblox's never follow the GUI scale).
		local live = HudLayout.compute(phone({ saving = true, buttons = { { x = 560, y = 200, w = 90, h = 150 } } }))
		local raised = live.saving
		t.ok(raised ~= nil and raised.y + raised.h <= 200, "above a big live button")
	end)

	t.test("hud layout: the corner keeps clear of the HUD's rows raised over the mana stars", function()
		-- (Ui/Hud moves the held item's name and the status row up to 20 GUI pixels over its canvas
		-- while Terraria's mana stars show: Ui/ManaStars.layout, UiScale.setHudRaise.)
		local checked = 0
		for _, screen in SCREENS do
			local w, h, inset = screen[1], screen[2], screen[3]
			for _, touch in { false, true } do
				local scale = GuiScale.base(w, h, touch, 0)
				for _, raise in { 0, 10, 20 } do
					local input = phone({
						width = w,
						height = h,
						insets = inset,
						scale = scale,
						touch = touch,
						music = true,
						saving = true,
						hudRaise = raise,
					})
					local layout = HudLayout.compute(input)
					local hud = layout.hud
					t.eq(hud.h, (HudLayout.HUD_HEIGHT + raise) * layout.scale, `{w} x {h}: raised {raise}`)
					for name, r in shown(input, layout) do
						t.ok(not HudLayout.overlaps(r, hud), `{w} x {h} raised {raise}: {name} off the HUD`)
					end
					checked += 1
				end
			end
		end
		t.eq(checked, #SCREENS * 2 * 3)
		-- Without a raise the HUD is its canvas, as before.
		local plain = HudLayout.compute(phone({}))
		t.eq(plain.hud.h, HudLayout.HUD_HEIGHT * plain.scale)
	end)

	t.test("hud layout: the toasts' slots, the Map button and WAILA's edges", function()
		-- 1920 x 1080 at Auto (4): the minimap 224 pixels, 16 from the corner under the top bar.
		local input = phone({ width = 1920, height = 1080, scale = 4, touch = false, coordsWidth = 56 })
		local layout = HudLayout.compute(input)
		local map = layout.minimap :: Rect
		t.eq(map.w, 224)
		t.eq(map.x, 1920 - 16 - 224)
		t.eq(map.y, 58 + 16)
		local coords = layout.coords :: Rect
		t.eq(coords.y, map.y + map.h + 8)
		local music = layout.music :: Rect
		t.eq(music.y, coords.y + coords.h + 8, "slot 1 under the coordinates line")
		t.eq(music.w, 640)
		-- "World saved" under Now Playing while it shows, in slot 1 otherwise.
		local both = HudLayout.compute(phone({
			width = 1920,
			height = 1080,
			scale = 4,
			touch = false,
			music = true,
			save = 200,
		}))
		local save = both.save :: Rect
		t.eq(save.y, (both.music :: Rect).y + 128 + 8)
		t.eq(save.w, 800, "as wide as its line")
		local alone = HudLayout.compute(phone({ width = 1920, height = 1080, scale = 4, touch = false, save = 160 }))
		t.eq((alone.save :: Rect).y, (alone.music :: Rect).y, "slot 1")
		local stays = HudLayout.compute(phone({
			width = 1920,
			height = 1080,
			scale = 4,
			touch = false,
			save = 160,
			saveUnder = true,
		}))
		t.eq((stays.save :: Rect).y, (stays.music :: Rect).y + 128 + 8, "it never moves back up while it shows")
		-- The effect icons go under the lowest toast showing.
		local effects = both.effects :: Rect
		t.eq(effects.y, save.y + save.h + 8)
		-- The minimap off: the Map button on touch screens, the toasts in the corner on a desktop.
		local off = HudLayout.compute(phone({ minimap = false }))
		t.ok(off.minimap == nil and off.coords == nil and off.mapButton ~= nil, "touch: the Map button")
		local desk =
			HudLayout.compute(phone({ width = 1920, height = 1080, scale = 4, touch = false, minimap = false }))
		t.ok(desk.mapButton == nil, "no Map button on a desktop")
		-- The minimap's weather button: a finger's size on touch (GUI pixels at the scale).
		for _, scale in { 1, 1.25, 1.5, 1.625, 2, 4 } do
			local side = HudLayout.touchSide(11, scale)
			t.ok(side * scale >= HudLayout.TOUCH_TARGET and side >= 11, `the weather button at {scale}`)
		end
		t.eq(HudLayout.touchSide(11, 4), 11, "big enough already at 4")
		t.eq((desk.music :: Rect).y, 58 + 16, "the toast in the corner")
		t.eq(desk.wailaRight, 1920 - 16, "nothing to keep out of")
		-- WAILA keeps right of the F3 text.
		local f3 = HudLayout.compute(phone({ width = 1920, height = 1080, scale = 4, touch = false, debugRight = 700 }))
		t.eq(f3.wailaAvoid, 708)
		t.eq(f3.wailaRight, (f3.minimap :: Rect).x - 8)
		-- A long coordinates line: WAILA keeps out of it only once it reaches down that far.
		local long = HudLayout.compute(phone({ width = 1920, height = 1080, scale = 4, touch = false }))
		local low = long.wailaLow :: { y: number, right: number }
		t.eq(long.wailaRight, (long.minimap :: Rect).x - 8, "beside the map")
		t.eq(low.right, (long.coords :: Rect).x - 8, "beside the coordinates line")
		t.eq(low.y, (long.coords :: Rect).y)
		-- Touch controls: PlayerModule's jump button.
		local small = HudLayout.jumpButton(667, 375, insets(0, 0, 0, 0, 58))
		t.ok(small.x == 572 and small.y == 285 and small.w == 70, "a phone's")
		local big = HudLayout.jumpButton(1024, 768, insets(0, 0, 0, 0, 58))
		t.ok(big.x == 854 and big.y == 558 and big.w == 120, "a tablet's")
		local notched = HudLayout.jumpButton(844, 390, insets(47, 0, 47, 21, 58))
		t.ok(notched.x == 844 - 47 - 95 and notched.y == 390 - 21 - 90, "inside the safe area")
		t.eq(#HudLayout.compute(phone({ touch = false })).buttons, 0, "none on a desktop")
	end)
end
