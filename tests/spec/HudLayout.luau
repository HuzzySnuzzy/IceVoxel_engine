--[[
	The HUD's shared corner (client Ui/HudLayout): over phones (568 x 320, 667 x 375, a notched
	844 x 390), tablets (1024 x 768), Studio's 1280 x 660, desktops (1366 x 768, 1920 x 1080,
	2560 x 1440) and 4K, times every GUI Scale choice the screen offers, the minimap on and off,
	touch on and off, the toasts and the saving icon showing or not and a few sets of effect icons:
	everything placed stays inside the safe area below the top bar; the minimap, its coordinates
	line, the Map button, the toasts, the effect icons, the saving icon, the touch buttons and the
	HUD's canvas never overlap (also while its rows are raised over the mana stars); WAILA's
	reserve covers the minimap column; the toasts start under the minimap's scaled bottom. Named
	regressions: on a 667 x 375 phone the effect icons ran past the bottom of the screen and the
	saving icon sat on the minimap (the corner was pinned to a 192 pixel minimap and raised by a
	fixed 150 GUI pixels).
]]

return function(t, _shared, require, _server, client)
	local GuiScale = require(client.Ui.GuiScale)
	local HudLayout = require(client.Ui.HudLayout)

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
