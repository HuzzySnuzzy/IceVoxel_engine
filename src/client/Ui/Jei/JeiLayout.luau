--!strict
--[[
	Where JEI's pieces go, in Minecraft GUI pixels like the other screens (Ui/MenuLayout). Pure: no
	Roblox APIs, so the tests check that nothing overlaps.

	  item list    the grid of every item at the right of the screen, beside the inventory panel:
	               the page row on top ("<", "n / m" or just "n" when narrow, ">"), rows of 18 x 18
	               item cells, the search field at the bottom. As many columns as fit right of the
	               panel (at most MAX_COLUMNS), centred in that space; fewer on narrow screens, and
	               none at all (hidden) when not even MIN_COLUMNS fit. As many rows as fit, up to
	               MAX_ROWS.
	  recipe view  a 176 x 166 panel (the inventory's size, so it takes the inventory's place) with
	               category tabs above it: the title row (Back, the category's name, a touch close
	               button), the page row, then as many recipes of the category as fit, each drawn
	               from the rectangles below (positions inside the recipe):

	                 crafting  116 x 54: the 3 x 3 grid, an arrow, the result in a large frame, the
	                           "+" (move the ingredients into the open grid) under it and the
	                           shapeless mark above it
	                 smelting  82 x 54: the input over a flame, the arrow (filling over the cooking
	                           time) and the output in a large frame, the time under them
	                 fuel      150 x 36: a flame burning down over the fuel's burn time over the
	                           fuel, two lines of text beside them
	                 refining  150 x 36: the oil (a fluid stack), an arrow filling over the time a
	                           bucket takes, the fuel, two lines of text right of them
	                 heating, combustion  150 x 36: as fuel, with the fluid stack under the flame
	                 boiling   as smelting (the dirty water over the campfire's flame, the arrow,
	                           the purified water), "Right click" under them

	A slot's (x, y) is its item's top left corner, as in MenuLayout (the frame is one pixel up and
	left, a large frame five).
]]

local JeiLayout = {}

export type Rect = { x: number, y: number, w: number, h: number }
export type Spot = { x: number, y: number, big: boolean }

-- An entry's drawing: its size and the rectangles of its parts (positions inside the entry).
export type EntryLayout = {
	w: number,
	h: number,
	-- Ingredient cells: crafting 1..9 (row by row), smelting and fuel 1.
	inputs: { Spot },
	output: Spot?,
	-- Fluid stacks (JEI's fluid ingredients, an 18 x 18 cell like a slot): taken, then made.
	fluidInputs: { Spot },
	fluidOutput: Spot?,
	arrow: Rect?,
	flame: Rect?,
	plus: Rect?,
	shapeless: Rect?,
	-- Text lines (right aligned for smelting's time).
	texts: { Rect },
}

export type ListLayout = {
	columns: number,
	rows: number,
	-- The list's top left in screen pixels and its size in GUI pixels (times `scale` on screen).
	x: number,
	y: number,
	width: number,
	height: number,
	scale: number,
}

JeiLayout.SLOT = 18
-- Item list: columns at most / at least (fewer than that hides the list), and rows at most (every
-- cell is a ViewportFrame: this bounds them on tall screens; 9 x 16 shows every item at once).
JeiLayout.MAX_COLUMNS = 9
JeiLayout.MIN_COLUMNS = 3
JeiLayout.MAX_ROWS = 16
-- GUI pixels: the page row above the grid, the search field row below it.
JeiLayout.NAV_HEIGHT = 16
JeiLayout.SEARCH_HEIGHT = 16
-- GUI pixels between the inventory panel and the list, and to the screen's edges.
JeiLayout.GAP = 6
JeiLayout.MARGIN = 4
-- Page row: arrow buttons at both ends.
JeiLayout.ARROW_W, JeiLayout.ARROW_H = 12, 12

-- Recipe view: the panel (the tabs add ItemIcon.TAB_HEIGHT above it).
JeiLayout.VIEW_WIDTH = 176
JeiLayout.VIEW_HEIGHT = 166
-- Title row and page row.
JeiLayout.TITLE_Y = 6
JeiLayout.BACK = { x = 5, y = 4, w = 36, h = 12 } :: Rect
JeiLayout.CLOSE = { x = 159, y = 4, w = 12, h = 12 } :: Rect
JeiLayout.PAGE_Y = 19
JeiLayout.PREV = { x = 7, y = 18, w = 12, h = 12 } :: Rect
JeiLayout.NEXT = { x = 157, y = 18, w = 12, h = 12 } :: Rect
-- Recipes go between AREA_TOP and AREA_BOTTOM, SPACING apart, centred.
JeiLayout.AREA_TOP = 34
JeiLayout.AREA_BOTTOM = 160
JeiLayout.SPACING = 6

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

local CRAFTING: EntryLayout = (function()
	local inputs: { Spot } = {}
	for row = 0, 2 do
		for column = 0, 2 do
			table.insert(inputs, { x = 1 + column * 18, y = 1 + row * 18, big = false })
		end
	end
	return {
		w = 116,
		h = 54,
		inputs = inputs,
		output = { x = 95, y = 19, big = true },
		fluidInputs = {},
		fluidOutput = nil,
		arrow = rect(62, 20, 22, 15),
		flame = nil,
		plus = rect(104, 42, 12, 12),
		shapeless = rect(107, 1, 9, 10),
		texts = {},
	}
end)()

local SMELTING: EntryLayout = {
	w = 82,
	h = 54,
	inputs = { { x = 1, y = 1, big = false } },
	output = { x = 61, y = 19, big = true },
	fluidInputs = {},
	fluidOutput = nil,
	arrow = rect(24, 18, 24, 16),
	flame = rect(2, 21, 14, 14),
	plus = nil,
	shapeless = nil,
	texts = { rect(0, 45, 82, 8) },
}

local FUEL: EntryLayout = {
	w = 150,
	h = 36,
	inputs = { { x = 1, y = 19, big = false } },
	output = nil,
	fluidInputs = {},
	fluidOutput = nil,
	arrow = nil,
	flame = rect(2, 2, 14, 14),
	plus = nil,
	shapeless = nil,
	texts = { rect(24, 9, 126, 8), rect(24, 21, 126, 8) },
}

local REFINING: EntryLayout = {
	w = 150,
	h = 36,
	inputs = {},
	output = nil,
	fluidInputs = { { x = 1, y = 10, big = false } },
	fluidOutput = { x = 55, y = 10, big = false },
	arrow = rect(24, 10, 24, 16),
	flame = nil,
	plus = nil,
	shapeless = nil,
	texts = { rect(78, 9, 72, 8), rect(78, 21, 72, 8) },
}

-- The generators burning a fluid: the fuel's layout with a fluid stack where its item goes.
local GENERATOR: EntryLayout = {
	w = 150,
	h = 36,
	inputs = {},
	output = nil,
	fluidInputs = { { x = 1, y = 19, big = false } },
	fluidOutput = nil,
	arrow = nil,
	flame = rect(2, 2, 14, 14),
	plus = nil,
	shapeless = nil,
	texts = { rect(24, 9, 126, 8), rect(24, 21, 126, 8) },
}

JeiLayout.ENTRIES = {
	crafting = CRAFTING,
	smelting = SMELTING,
	fuel = FUEL,
	refining = REFINING,
	heating = GENERATOR,
	combustion = GENERATOR,
	boiling = SMELTING,
} :: { [string]: EntryLayout }

function JeiLayout.entry(category: string): EntryLayout
	return JeiLayout.ENTRIES[category] or CRAFTING
end

-- How many recipes of a category one page of the view shows.
function JeiLayout.perPage(category: string): number
	local h = JeiLayout.entry(category).h
	local area = JeiLayout.AREA_BOTTOM - JeiLayout.AREA_TOP
	return math.max(1, math.floor((area + JeiLayout.SPACING) / (h + JeiLayout.SPACING)))
end

--[[
	Top left (inside the panel) of the `index`th recipe (1-based) of a page with `shown` recipes:
	centred horizontally, the column of recipes centred in the area.
]]
function JeiLayout.entryOrigin(category: string, index: number, shown: number): (number, number)
	local layout = JeiLayout.entry(category)
	local total = shown * layout.h + math.max(0, shown - 1) * JeiLayout.SPACING
	local top = JeiLayout.AREA_TOP + math.floor((JeiLayout.AREA_BOTTOM - JeiLayout.AREA_TOP - total) / 2)
	local x = math.floor((JeiLayout.VIEW_WIDTH - layout.w) / 2)
	return x, top + (index - 1) * (layout.h + JeiLayout.SPACING)
end

--[[
	The item list for a `viewportX`-wide screen whose usable height runs from `top` to `bottom`
	(screen pixels), right of an inventory panel ending at `guiRight`, at GUI scale `scale`. nil when
	it does not fit (hidden).
]]
function JeiLayout.list(viewportX: number, top: number, bottom: number, guiRight: number, scale: number): ListLayout?
	if scale <= 0 then
		return nil
	end
	local slot = JeiLayout.SLOT
	-- In GUI pixels: from the panel's right edge (plus the gap) to the screen's edge (less the margin).
	local left = guiRight / scale + JeiLayout.GAP
	local space = viewportX / scale - JeiLayout.MARGIN - left
	local columns = math.min(JeiLayout.MAX_COLUMNS, math.floor(space / slot))
	local height = (bottom - top) / scale - 2 * JeiLayout.MARGIN
	local rows =
		math.min(JeiLayout.MAX_ROWS, math.floor((height - JeiLayout.NAV_HEIGHT - JeiLayout.SEARCH_HEIGHT) / slot))
	if columns < JeiLayout.MIN_COLUMNS or rows < 1 then
		return nil
	end
	local width = columns * slot
	local x = left + math.floor((space - width) / 2)
	return {
		columns = columns,
		rows = rows,
		x = x * scale,
		y = top + JeiLayout.MARGIN * scale,
		width = width,
		height = JeiLayout.NAV_HEIGHT + rows * slot + JeiLayout.SEARCH_HEIGHT,
		scale = scale,
	}
end

--[[
	The page row's text: "n / m", or just "n" when that is wider than `room` GUI pixels (a narrow
	list; `measure` gives a text's width, Style.textWidth).
]]
function JeiLayout.pageText(page: number, pages: number, room: number, measure: (text: string) -> number): string
	local text = `{page} / {pages}`
	if measure(text) <= room then
		return text
	end
	return tostring(page)
end

-- The list's parts in its own GUI pixels: the page arrows and text, the grid's top, the search field.
function JeiLayout.listParts(layout: ListLayout): { prev: Rect, next: Rect, page: Rect, grid: Rect, search: Rect }
	local w = layout.width
	local gridTop = JeiLayout.NAV_HEIGHT
	local gridHeight = layout.rows * JeiLayout.SLOT
	return {
		prev = rect(0, 1, JeiLayout.ARROW_W, JeiLayout.ARROW_H),
		next = rect(w - JeiLayout.ARROW_W, 1, JeiLayout.ARROW_W, JeiLayout.ARROW_H),
		page = rect(JeiLayout.ARROW_W, 3, w - 2 * JeiLayout.ARROW_W, 8),
		grid = rect(0, gridTop, w, gridHeight),
		search = rect(0, gridTop + gridHeight + 3, w, 12),
	}
end

return JeiLayout
