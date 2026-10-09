--[[
	Minecraft's GUI Scale (client Ui/GuiScale): Window.calculateScale's automatic scale (640 x 480
	is 2, 1280 x 720 3, 1920 x 1080 4, 2560 x 1440 6, 3840 x 2160 9), eighths on touch screens,
	Auto always the largest choice, every choice offered drawing differently, a stored choice above
	a screen's largest acting as the largest, shrinking to fit (whole scales on a desktop, eighths
	below 1 and on touch, never below 0.5), the reference scale of fixed-pixel widgets, and scales
	that never shrink as the screen grows.
]]

return function(t, _shared, require, _server, client)
	local GuiScale = require(client.Ui.GuiScale)

	t.test("gui scale: Minecraft's automatic scale on a desktop, eighths on touch", function()
		for _, case in
			{
				{ 640, 480, 2 },
				{ 1280, 720, 3 },
				{ 1280, 660, 2 },
				{ 1366, 768, 3 },
				{ 1920, 1080, 4 },
				{ 2560, 1440, 6 },
				{ 3840, 2160, 9 },
				{ 300, 200, 1 },
				{ 7680, 4320, 12 },
			}
		do
			t.eq(GuiScale.auto(case[1], case[2], false), case[3], `{case[1]} x {case[2]}`)
		end
		t.eq(GuiScale.auto(667, 375, true), 1.5, "a small phone")
		t.eq(GuiScale.auto(844, 390, true), 1.625, "a notched phone")
		t.eq(GuiScale.auto(1024, 768, true), 3.125, "a tablet (3.2 in eighths)")
		t.eq(GuiScale.auto(100, 80, true), 0.5, "never below half")
	end)

	t.test("gui scale: Auto is the largest choice, and every choice draws differently", function()
		for _, screen in { { 640, 480 }, { 1280, 720 }, { 1920, 1080 }, { 2560, 1440 }, { 3840, 2160 } } do
			local w, h = screen[1], screen[2]
			t.eq(GuiScale.base(w, h, false, 0), GuiScale.maxChoice(w, h, false), `{w} x {h}: Auto is the largest`)
			local choices = GuiScale.choices(w, h, false)
			t.eq(choices[1], 0, "Auto first")
			t.eq(#choices, GuiScale.maxChoice(w, h, false) + 1)
			local seen = {}
			for i = 2, #choices do
				local base = GuiScale.base(w, h, false, choices[i])
				t.ok(seen[base] == nil, `{w} x {h}: choice {choices[i]} draws like another`)
				seen[base] = true
			end
		end
		t.eq(GuiScale.maxChoice(667, 375, true), 1)
		t.eq(GuiScale.base(667, 375, true, 1), 1)
		t.eq(GuiScale.base(667, 375, true, nil), 1.5)
		-- A stored choice above the screen's largest acts as the largest (and comes back on a bigger one).
		t.eq(GuiScale.base(1280, 720, false, 6), 3)
		t.eq(GuiScale.base(2560, 1440, false, 6), 6)
		t.eq(GuiScale.base(1920, 1080, false, 0 / 0), 4, "junk is Auto")
	end)

	t.test("gui scale: fitting content, the reference scale, and growing with the screen", function()
		-- The 176 x 166 inventory at 4 needs 704 x 664 + the margins.
		t.eq(GuiScale.fit(4, 176, 166, 1920, 1080, false), 4)
		t.eq(GuiScale.fit(4, 176, 166, 700, 1080, false), 3, "whole scales on a desktop")
		t.eq(GuiScale.fit(4, 176, 166, 150, 1080, false), 0.75, "eighths below 1")
		t.eq(GuiScale.fit(1.5, 176, 166, 667, 375, true), 1.5, "the inventory fits a small phone at its base")
		t.eq(GuiScale.fit(1.625, 400, 300, 667, 375, true), 1.125, "touch: eighths")
		t.eq(GuiScale.fit(3, 1000, 1000, 100, 100, false), 0.5, "never below half")
		-- The title screen's pages (320 x 240, laid out down to 236) below a 58 pixel top bar: a
		-- 1366 x 768 window keeps its Auto 3, and its choices 3 and 2 differ.
		local base = GuiScale.base(1366, 768, false, 0)
		t.eq(base, 3)
		t.eq(GuiScale.fit(base, 320, 240, 1366, 768 - 58, false), 2, "240 and the margins: a step less")
		t.eq(GuiScale.fit(base, 320, 240, 1366, 768 - 58, false, 236), 3, "the pages' 236 fit at 3")
		t.eq(GuiScale.fit(2, 320, 240, 1366, 768 - 58, false, 236), 2)
		t.eq(GuiScale.fit(4, 320, 240, 1366, 768 - 58, false, 236), 2, "too big a base still shrinks")
		t.eq(GuiScale.reference(4), 1, "1080p's Auto draws fixed pixels as they are")
		t.eq(GuiScale.reference(6), 1.5)
		t.eq(GuiScale.reference(1.5), 0.75, "at least three quarters")
		local last = 0
		for w = 300, 4000, 37 do
			local scale = GuiScale.auto(w, math.floor(w * 9 / 16), false)
			t.ok(scale >= last, `{w}: never smaller on a bigger screen`)
			last = scale
		end
	end)
end
