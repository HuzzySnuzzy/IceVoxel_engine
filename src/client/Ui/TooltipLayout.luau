--!strict
--[[
	The menu tooltip's shape and place, pure (no Roblox APIs, so the tests run it): the text
	wrapped into rows, the box's size, and where it goes on the screen. Ui/HoverTip draws it.
	Everything is in GUI pixels (the caller divides screen pixels by the GUI scale first).

	  wrap          `text` cut into rows of at most WIDTH pixels at word breaks (Ui/TextWrap); a
	                "\n" starts a new row (an empty line between paragraphs stays one).
	  size          Minecraft's tooltip box around rows: PAD pixels of padding, rows LINE pixels
	                apart, TEXT pixels tall.
	  nearPointer   Minecraft's DefaultTooltipPositioner (a mouse hovering): 12 right of and 12
	                above the pointer; past the screen's right edge it flips to the pointer's left
	                (24 back, at least EDGE from the left); past the bottom it moves up so 3
	                pixels stay under it; never above EDGE.
	  aboveTouch    a long press: centred over the finger and FINGER above it (the finger covers
	                what is under it); below the finger when there is no room above; kept EDGE
	                inside the screen's sides.
	  belowOrAbove  Minecraft's BelowOrAboveWidgetTooltipPositioner (a gamepad or keyboard
	                selection): GAP under the widget, its left edge at the widget's (moved left to
	                end inside the screen); above the widget when it would reach past the bottom
	                and there is room above.
]]

local TextWrap = require(script.Parent.TextWrap)

export type Measure = (text: string) -> number

local TooltipLayout = {}

-- The width text wraps at (Minecraft splits option tooltips at a fixed width; this pixel font is
-- wider than Minecraft's), the padding around the text, the row pitch and the text's height.
TooltipLayout.WIDTH = 200
TooltipLayout.PAD = 4
TooltipLayout.LINE = 10
TooltipLayout.TEXT = 8
-- Minecraft's pointer offset (DefaultTooltipPositioner), the margin kept to the screen's edges,
-- the gap to a widget and how far above a finger a long press's tooltip sits.
TooltipLayout.OFFSET = 12
TooltipLayout.EDGE = 4
TooltipLayout.GAP = 4
TooltipLayout.FINGER = 28

-- `text` in rows of at most `width` pixels (default WIDTH), measured by `measure`.
function TooltipLayout.wrap(text: string, measure: Measure, width: number?): { string }
	local rows: { string } = {}
	for paragraph in string.gmatch(text .. "\n", "([^\n]*)\n") do
		for _, row in TextWrap.wrap(paragraph, width or TooltipLayout.WIDTH, measure) do
			table.insert(rows, row)
		end
	end
	return rows
end

-- The box's width and height around `rows` (the widest row plus the padding).
function TooltipLayout.size(rows: { string }, measure: Measure): (number, number)
	local width = 0
	for _, row in rows do
		width = math.max(width, measure(row))
	end
	local count = math.max(#rows, 1)
	return width + 2 * TooltipLayout.PAD, (count - 1) * TooltipLayout.LINE + TooltipLayout.TEXT + 2 * TooltipLayout.PAD
end

-- Where a `w` x `h` tooltip goes for a pointer at (px, py) on a `screenW` x `screenH` screen.
function TooltipLayout.nearPointer(
	px: number,
	py: number,
	w: number,
	h: number,
	screenW: number,
	screenH: number
): (number, number)
	local offset, edge = TooltipLayout.OFFSET, TooltipLayout.EDGE
	local x = px + offset
	if x + w > screenW then
		x = math.max(px - 2 * offset - w, edge)
	end
	local y = py - offset
	if y + h + 3 > screenH then
		y = screenH - h - 3
	end
	return x, math.max(y, edge)
end

-- Where a `w` x `h` tooltip goes for a finger held at (px, py).
function TooltipLayout.aboveTouch(
	px: number,
	py: number,
	w: number,
	h: number,
	screenW: number,
	screenH: number
): (number, number)
	local edge = TooltipLayout.EDGE
	local x = math.clamp(px - w / 2, edge, math.max(edge, screenW - w - edge))
	local y = py - TooltipLayout.FINGER - h
	if y < edge then
		y = math.min(py + TooltipLayout.FINGER, math.max(edge, screenH - h - edge))
	end
	return math.floor(x), math.floor(y)
end

-- Where a `w` x `h` tooltip goes for the widget at (x, y), `rw` x `rh`, on a `screenW` x `screenH`
-- screen (or panel).
function TooltipLayout.belowOrAbove(
	rx: number,
	ry: number,
	_rw: number,
	rh: number,
	w: number,
	h: number,
	screenW: number,
	screenH: number
): (number, number)
	local x = math.max(0, math.min(rx, screenW - w))
	local below = ry + rh + TooltipLayout.GAP
	local above = ry - TooltipLayout.GAP - h
	local y = if below + h > screenH and above >= 0 then above else below
	return x, y
end

return TooltipLayout
