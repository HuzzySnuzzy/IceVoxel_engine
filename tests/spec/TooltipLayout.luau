--[[
	The menu tooltip's shape and place (client Ui/TooltipLayout, drawn by Ui/HoverTip): text wrapped
	to WIDTH at word breaks with "\n" starting a row, the box around the rows, and the three
	placements: near a mouse pointer (Minecraft's DefaultTooltipPositioner: right of and above it,
	flipped left at the screen's edge, moved up at the bottom), above a held finger (below it when
	there is no room) and under or over a selected widget, always on the screen.
]]

-- The pixel font's advance in tests: 8 GUI pixels a character.
local function measure(text: string): number
	return #text * 8
end

return function(t, _shared, require, _server, client)
	local TooltipLayout = require(client.Ui.TooltipLayout)
	local PAD, LINE, TEXT = TooltipLayout.PAD, TooltipLayout.LINE, TooltipLayout.TEXT
	local OFFSET, EDGE, GAP = TooltipLayout.OFFSET, TooltipLayout.EDGE, TooltipLayout.GAP

	t.test("tooltip layout: wraps at word breaks to WIDTH; a newline starts a row", function()
		local rows = TooltipLayout.wrap("one two three", measure, 64)
		t.eq(#rows, 2, "two rows at 8 characters")
		t.eq(rows[1], "one two")
		t.eq(rows[2], "three")
		for _, row in TooltipLayout.wrap(string.rep("word ", 40), measure) do
			t.ok(measure(row) <= TooltipLayout.WIDTH, `"{row}" fits WIDTH`)
		end
		local paragraphs = TooltipLayout.wrap("first\n\nsecond", measure)
		t.eq(#paragraphs, 3, "a newline is a row break, an empty line stays")
		t.eq(paragraphs[1], "first")
		t.eq(paragraphs[2], "")
		t.eq(paragraphs[3], "second")
		t.eq(#TooltipLayout.wrap("", measure), 1, "an empty text is one empty row")
	end)

	t.test("tooltip layout: the box is the widest row and the rows, padded", function()
		local w, h = TooltipLayout.size({ "abc", "abcdef" }, measure)
		t.eq(w, 6 * 8 + 2 * PAD, "the widest row")
		t.eq(h, LINE + TEXT + 2 * PAD, "two rows LINE apart")
		local w1, h1 = TooltipLayout.size({ "x" }, measure)
		t.eq(w1, 8 + 2 * PAD)
		t.eq(h1, TEXT + 2 * PAD, "one row")
		local _, h0 = TooltipLayout.size({}, measure)
		t.eq(h0, TEXT + 2 * PAD, "no rows: one row's height")
	end)

	t.test("tooltip layout: near the pointer, Minecraft's default positioner, kept on the screen", function()
		local W, H = 480, 270
		local x, y = TooltipLayout.nearPointer(100, 100, 120, 40, W, H)
		t.eq(x, 100 + OFFSET, "right of the pointer")
		t.eq(y, 100 - OFFSET, "above it")
		local fx = TooltipLayout.nearPointer(420, 100, 120, 40, W, H)
		t.eq(fx, 420 - 2 * OFFSET - 120, "flipped left of the pointer at the right edge")
		t.ok(fx + 120 <= W, "inside the screen")
		local ex = TooltipLayout.nearPointer(130, 100, 200, 40, 300, H)
		t.eq(ex, EDGE, "never past the left edge when it fits neither side")
		local _, by = TooltipLayout.nearPointer(100, 260, 120, 40, W, H)
		t.eq(by, H - 40 - 3, "moved up at the bottom, 3 pixels under it")
		local _, ty = TooltipLayout.nearPointer(100, 2, 120, 40, W, H)
		t.eq(ty, EDGE, "never above the top")
		local _, tall = TooltipLayout.nearPointer(100, 100, 120, 400, W, H)
		t.eq(tall, EDGE, "a box taller than the screen starts at the top")
	end)

	t.test("tooltip layout: a long press shows it over the finger, or under it at the top", function()
		local W, H = 480, 270
		local x, y = TooltipLayout.aboveTouch(240, 200, 100, 30, W, H)
		t.eq(x, 190, "centred on the finger")
		t.eq(y, 200 - TooltipLayout.FINGER - 30, "above it, clear of the finger")
		local _, below = TooltipLayout.aboveTouch(240, 20, 100, 30, W, H)
		t.eq(below, 20 + TooltipLayout.FINGER, "under the finger near the top")
		local left = TooltipLayout.aboveTouch(10, 200, 100, 30, W, H)
		t.eq(left, EDGE, "kept inside the left edge")
		local right = TooltipLayout.aboveTouch(475, 200, 100, 30, W, H)
		t.eq(right, W - 100 - EDGE, "kept inside the right edge")
		local _, low = TooltipLayout.aboveTouch(240, 20, 100, 260, W, H)
		t.ok(low >= EDGE and low <= H, "a tall box near the top stays on the screen")
	end)

	t.test("tooltip layout: a selected widget's tooltip goes under it, or over it at the bottom", function()
		local W, H = 480, 270
		local x, y = TooltipLayout.belowOrAbove(40, 50, 150, 20, 120, 40, W, H)
		t.eq(x, 40, "its left edge at the widget's")
		t.eq(y, 50 + 20 + GAP, "under the widget")
		local _, above = TooltipLayout.belowOrAbove(40, 230, 150, 20, 120, 40, W, H)
		t.eq(above, 230 - GAP - 40, "over it near the bottom")
		t.ok(above + 40 <= 230, "never over the widget")
		local mx = TooltipLayout.belowOrAbove(420, 50, 50, 20, 120, 40, W, H)
		t.eq(mx, W - 120, "moved left to end inside the screen")
		local _, cramped = TooltipLayout.belowOrAbove(40, 10, 150, 250, 120, 40, W, H)
		t.eq(cramped, 10 + 250 + GAP, "no room above either: under it")
	end)
end
