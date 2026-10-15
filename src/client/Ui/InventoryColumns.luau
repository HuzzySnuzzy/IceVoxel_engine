--!strict
--[[
	The survival look's inventory screen, laid out in GUI pixels: where every column, header,
	section, slot, eye and the quickbar band go, and the GUI scale the whole screen is drawn at.
	Pure (no Roblox APIs): Ui/InventoryScreen draws what this says, and tests/spec/InventoryColumns
	checks every layout it can make.

	Wide mode: three columns over a band, `364 + centreW` wide (450 at the smallest centre):

	    x 0          176 182         182+c  188+c          364+c
	      +------------+   +-------------+   +--------------+
	      | VICINITY   |   |             |   | EQUIPMENT    |   grey top headers, `top` tall
	      | ground     |   |  character  |   | worn strip   |   headerless strips right under them
	      | CRAFTING   |   |             |   | BACKPACK     |   sections: a 14 px bar, then the
	      |  (or the   |   |-------------|   | VANITY       |   body, 2 px between sections
	      |   block's) |   | HANDS       |   |              |
	      | ITEMS      |   |             |   |              |
	      +------------+   +-------------+   +--------------+
	      | effects      quickbar (182 x 22, centred)       status (93 x 23) |   the band, 26 tall

	Narrow mode (a small screen, where wide would fall below MIN_WIDE_SCALE): the left and the
	right columns only, 358 wide; no character and no HANDS.

	The rules:

	  * Columns: left (x 0), centre (x 182, wide only, `centreW` wide: CENTRE_W, more on a PC with
	    spare width, up to CENTRE_MAX) and right, COLUMN_GAP apart. Each side column starts with its
	    top header at y 0 (`top` tall: Theme's TOP_HEADER on a mouse; on touch `topHeader`, 32
	    screen pixels at the base scale and never under 22 GUI pixels). The centre has no top header.
	  * Stacking: the headerless strips (the GROUND strip on the left, the worn-slot strip on the
	    right) sit right under their top header; every other section follows the previous one
	    SECTION_GAP below, a 14 px bar and its body (only the bar while collapsed).
	      left    ground (22), then CRAFTING (window 0, 40) or the open block's section (its
	              MenuLayout panel less the BODY_CUT title strip), then ITEMS (JEI's list) taking
	              the rest of the column
	      centre  the character from y 0, HANDS (a 14 px grey header and a 62 px body) at the
	              bottom of the column
	      right   the worn strip (window 0: armor over the accessories, 42; on touch 58 with a row
	              of eyes; other windows: the armor alone, 22), BACKPACK (58), VANITY (window 0, 42)
	    Collapsible: CRAFTING, the block's section, ITEMS, BACKPACK and VANITY (the `collapsed`
	    bitmask, BIT). A collapsed section is its bar alone; a section's slots are live only while
	    it is present and open (`live`). Its title's count comes from the window (`used`), so a
	    collapsed BACKPACK or chest still says how full it is.
	  * Heights: the root is at least the tallest column (ITEMS at JEI_MIN, the character at
	    CHARACTER_MIN) plus the band (`minimum`), at most MAX_HEIGHT; extra height goes to ITEMS on
	    the left and to the character in the centre.
	  * The band: the open window's nine hotbar slots as the quickbar (HudLayout's cell maths:
	    quickCell and quickIcon from the bar's top left), centred when that leaves the status
	    icons' room at its right (wide), else at the left; the status icons' place at the band's
	    right when they fit beside the bar; the effect icons' place (`effects`, as tall as the
	    bar) in the wider free stretch beside the bar: its left while the bar is centred, else
	    between the bar and the status icons, BAND_GAP from each. While the recipe view is open
	    (over the centre and right columns, which hide with the bar) the effect icons take the
	    band's row under the left column instead (`viewEffects`, LEFT_W wide, on the bar's line):
	    the view, centred at `viewCentre` and never wider than JeiLayout.VIEW_WIDTH there, starts
	    right of it in both modes.
	  * Slots keep the 18 px pitch of MenuLayout (whose coordinates and the CraftingUi spec stay):
	    a slot's (x, y) is its item's top left, its 18 x 18 frame one pixel up and left (a large
	    result's 26 x 26 frame five), and its grid lines at x - 1 and x + 17 (big: x - 5, x + 20),
	    shared with its neighbours (`gridLines`: no pixel painted twice).
	  * The block's section draws MenuLayout's panel with its title strip cut off: every spot,
	    gauge, bar, tank, status and line is moved up BODY_CUT (`containerOffset`).
	  * Throwing: the GROUND strip (`drop`) is the only place inside the screen that throws.

	The GUI scale (`place`, the only scale rule): the scale the screen fits at in each mode
	(GuiScale.fit, keeping the base whenever the smallest layout fits whole), wide when that is at
	least min(base, MIN_WIDE_SCALE) (touch: MIN_WIDE_SCALE_TOUCH), else narrow; on a PC the bottom
	is lifted INSET of the screen's height (DayZ's safe frame, the HUD quickbar's baseline) and the
	centre widens until the side columns reach INSET of the width in from the edges; the height
	fills the screen down to the margins, and the root is centred horizontally and sits at the
	bottom of the area (its band on the HUD quickbar's line), GuiScale.MARGIN above it. Only the
	least height can leave less than both margins (GuiScale.fit keeps the base whenever that height
	fits the area at all, margins or not, as it does on a 360 px tall phone): the root then gives up
	the margin at its top first (keeping its band on the quickbar's line), then the one at its
	bottom, and never reaches past the area's bottom.

	Rects are { x, y, w, h }. Section rects are root coordinates; spots, eyes and the HANDS parts
	are their section body's.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Types = require(Shared.Inventory.Types)

local GuiScale = require(script.Parent.GuiScale)
local HudLayout = require(script.Parent.HudLayout)
local MenuLayout = require(script.Parent.MenuLayout)
local Theme = require(script.Parent.Theme)

local Size = Theme.Size

export type Rect = { x: number, y: number, w: number, h: number }
export type Mode = "wide" | "narrow"
export type Kind = "ground" | "craft" | "container" | "jei" | "character" | "hands" | "equipment" | "backpack" | "vanity"
-- What a spot is a slot of (Menu.windowIndex's stores), or a GROUND strip place ("ground").
export type Store = "container" | "armor" | "inventory" | "accessory" | "vanityArmor" | "vanityAccessory" | "ground"
-- A slot in a section body: its store and index there (MenuLayout.Spot's fields besides).
export type Spot = { store: Store, slot: number, x: number, y: number, big: boolean, ghost: { string }? }

--[[
	What the screen shows, for `arrange`: the mode, the input kind, the top headers' height, the
	open block's MenuLayout panel height and the panel itself (nil: window 0, CRAFTING), whether
	the equipment (accessories, vanity) is shown (window 0), the collapsed sections (BIT
	bitmask: no table per call), and the root's height and the centre's width (nil: the least).
]]
export type Input = {
	mode: Mode,
	touch: boolean,
	top: number,
	container: number?,
	panel: MenuLayout.Panel?,
	equipment: boolean,
	collapsed: number,
	height: number?,
	centreW: number?,
}

-- A section of a column (root coordinates): its bar's height (0: a headerless strip) and body's.
export type Section = {
	kind: Kind,
	-- 1 left, 2 centre, 3 right.
	column: number,
	x: number,
	y: number,
	w: number,
	header: number,
	-- 0 while collapsed.
	body: number,
	collapsible: boolean,
	collapsed: boolean,
}

export type Arrangement = {
	mode: Mode,
	width: number,
	height: number,
	-- Each column above the band, by column number (narrow: 1 and 3).
	columns: { [number]: Rect },
	-- The two top headers (left, right) and their texts.
	tops: { Rect },
	titles: { string },
	sections: { Section },
	-- The sections by kind (a Kind string).
	byKind: { [string]: Section },
	-- ITEMS' body (nil while collapsed), the GROUND strip (the throw target), the band, the
	-- quickbar in it, the status icons' place (nil when they do not fit beside the bar), the
	-- effect icons' (nil when not one fits) and theirs while the recipe view is open (`viewEffects`:
	-- the band's row under the left column, which stays beside the view; the bar hides).
	jei: Rect?,
	drop: Rect,
	band: Rect,
	quickbar: Rect,
	status: Rect?,
	effects: Rect?,
	viewEffects: Rect,
}

-- The screens GUI as `place` sees it (screen pixels: its AbsoluteSize, Roblox's top bar).
export type View = { w: number, h: number, top: number, base: number, touch: boolean }

-- The mode, GUI scale, height and centre width chosen, and the root's top left (screen pixels).
export type Placement = {
	mode: Mode,
	scale: number,
	height: number,
	centreW: number,
	x: number,
	y: number,
}

-- HANDS' body: the black name bar, the condition dot in it, the item, the condition and detail.
export type HandsLayout = { bar: Rect, dot: Rect, item: Rect, condition: Rect, detail: Rect }

local InventoryColumns = {}

InventoryColumns.LEFT_W, InventoryColumns.RIGHT_W = 176, 176
-- The centre's least width (the character and HANDS), and the most it grows to on a PC.
InventoryColumns.CENTRE_W = 86
InventoryColumns.CENTRE_MAX = 176
-- The root's tallest (columns and band).
InventoryColumns.MAX_HEIGHT = 320
-- Wide mode down to this scale (mouse, touch), or to the base when that is smaller.
InventoryColumns.MIN_WIDE_SCALE = 2
InventoryColumns.MIN_WIDE_SCALE_TOUCH = 1.5
-- On a PC the side columns reach this share of the width in, and the bottom lifts this share of
-- the height.
InventoryColumns.INSET = 0.05
-- A block panel's title strip (MenuLayout panels start their content at y >= 13).
InventoryColumns.BODY_CUT = 12
-- Section bodies.
InventoryColumns.GROUND_H = 22
InventoryColumns.CRAFT_H = 40
-- CRAFTING's chevron between the 2 x 2 grid and its result (body coordinates).
InventoryColumns.CRAFT_ARROW = table.freeze({ x = 86, y = 14, w = 16, h = 13 }) :: Rect
InventoryColumns.BACKPACK_H = 58
InventoryColumns.VANITY_H = 42
-- The worn strip: window 0 on a mouse, on touch (a row of eyes), other windows (armor only).
InventoryColumns.STRIP_H = 42
InventoryColumns.STRIP_TOUCH_H = 58
InventoryColumns.STRIP_ARMOR_H = 22
-- ITEMS at its least: header 14 + pad 1 + nav 16 + one row 18 + search 16 + pad 1.
InventoryColumns.JEI_MIN = 66
InventoryColumns.CHARACTER_MIN = 96
-- HANDS: its grey header 14, the name bar 14, the item and its lines 48.
InventoryColumns.HANDS_H = 76
-- The status icons docked in the band (Ui/StatusDock; the notifier row only).
InventoryColumns.STATUS_W, InventoryColumns.STATUS_H = 93, 23
-- The quickbar in the band (HudLayout's bar), and the GROUND strip's places.
InventoryColumns.QUICK_W, InventoryColumns.QUICK_H = 182, 22
-- The effect icons' place in the band (Ui/EffectHud draws them there, as tall as the bar) is
-- at least this wide (one icon), and keeps BAND_GAP from the quickbar and the status icons.
InventoryColumns.EFFECTS_MIN_W = 22
InventoryColumns.BAND_GAP = 4
InventoryColumns.GROUND_SLOTS = 9
-- Collapse bits (Input.collapsed).
InventoryColumns.BIT = table.freeze({ craft = 1, container = 2, jei = 4, backpack = 8, vanity = 16 })

local LEFT_W, RIGHT_W = InventoryColumns.LEFT_W, InventoryColumns.RIGHT_W
local CENTRE_W, CENTRE_MAX = InventoryColumns.CENTRE_W, InventoryColumns.CENTRE_MAX
local MAX_HEIGHT = InventoryColumns.MAX_HEIGHT
local INSET = InventoryColumns.INSET
local BODY_CUT = InventoryColumns.BODY_CUT
local GROUND_H, CRAFT_H = InventoryColumns.GROUND_H, InventoryColumns.CRAFT_H
local BACKPACK_H, VANITY_H = InventoryColumns.BACKPACK_H, InventoryColumns.VANITY_H
local JEI_MIN, CHARACTER_MIN, HANDS_H =
	InventoryColumns.JEI_MIN, InventoryColumns.CHARACTER_MIN, InventoryColumns.HANDS_H
local STATUS_W, STATUS_H = InventoryColumns.STATUS_W, InventoryColumns.STATUS_H
local QUICK_W, QUICK_H = InventoryColumns.QUICK_W, InventoryColumns.QUICK_H
local EFFECTS_MIN_W, BAND_GAP = InventoryColumns.EFFECTS_MIN_W, InventoryColumns.BAND_GAP
local SECTION_HEADER, SECTION_GAP = Size.SECTION_HEADER, Size.SECTION_GAP
local COLUMN_GAP, QUICK_BAND = Size.COLUMN_GAP, Size.QUICK_BAND
local PITCH = Size.PITCH
local BIT = InventoryColumns.BIT
-- The narrow and the least wide widths.
local NARROW_W = LEFT_W + COLUMN_GAP + RIGHT_W
local SIDES_W = NARROW_W + COLUMN_GAP

local TITLES = table.freeze({ "VICINITY", "EQUIPMENT" })

--[[ Pieces ]]

--[[
	The top headers' height: TOP_HEADER on a mouse; on touch a finger's HudLayout.TOUCH_TARGET screen
	pixels at `base`, never under Theme's TOUCH_HEADER_MIN.
]]
function InventoryColumns.topHeader(touch: boolean, base: number): number
	if not touch then
		return Size.TOP_HEADER
	end
	if base ~= base or base <= 0 then
		return Size.TOUCH_HEADER_MIN
	end
	return math.max(Size.TOUCH_HEADER_MIN, math.ceil(HudLayout.TOUCH_TARGET / base))
end

-- Is `kind` collapsed in `input`'s bitmask? (Only the collapsible kinds have a bit.)
local function isCollapsed(input: Input, kind: Kind): boolean
	local bit = (BIT :: any)[kind]
	return bit ~= nil and bit32.btest(input.collapsed, bit)
end

local function stripHeight(input: Input): number
	if not input.equipment then
		return InventoryColumns.STRIP_ARMOR_H
	end
	return if input.touch then InventoryColumns.STRIP_TOUCH_H else InventoryColumns.STRIP_H
end

local function centreWidth(input: Input): number
	local w = input.centreW or CENTRE_W
	return math.clamp(math.floor(w), CENTRE_W, CENTRE_MAX)
end

-- The left column's block section: its kind and full body height.
local function blockSection(input: Input): (Kind, number)
	local height = input.container
	if height then
		return "container", math.max(0, height - BODY_CUT)
	end
	return "craft", CRAFT_H
end

-- The bottom of the left column with ITEMS at its least.
local function leftBottom(input: Input): number
	local kind: Kind, body: number = blockSection(input)
	local y = input.top + GROUND_H + SECTION_GAP
	y += SECTION_HEADER + (if isCollapsed(input, kind) then 0 else body) + SECTION_GAP
	return y + (if isCollapsed(input, "jei") then SECTION_HEADER else JEI_MIN)
end

-- The bottom of the right column.
local function rightBottom(input: Input): number
	local y = input.top + stripHeight(input) + SECTION_GAP
	y += SECTION_HEADER + (if isCollapsed(input, "backpack") then 0 else BACKPACK_H)
	if input.equipment then
		y += SECTION_GAP + SECTION_HEADER + (if isCollapsed(input, "vanity") then 0 else VANITY_H)
	end
	return y
end

-- The root's width and least height for `input` (its mode, top, sections).
function InventoryColumns.minimum(input: Input): (number, number)
	local wide = input.mode == "wide"
	local width = if wide then SIDES_W + centreWidth(input) else NARROW_W
	local tallest = math.max(leftBottom(input), rightBottom(input))
	if wide then
		tallest = math.max(tallest, CHARACTER_MIN + SECTION_GAP + HANDS_H)
	end
	return width, tallest + QUICK_BAND
end

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

--[[ The arrangement ]]

-- The whole screen for `input` (see the header).
function InventoryColumns.arrange(input: Input): Arrangement
	local wide = input.mode == "wide"
	local width, least = InventoryColumns.minimum(input)
	local height = math.max(least, math.min(math.floor(input.height or least), MAX_HEIGHT))
	local columnH = height - QUICK_BAND
	local top = input.top
	local centreW = centreWidth(input)
	local centreX = LEFT_W + COLUMN_GAP
	local rightX = if wide then centreX + centreW + COLUMN_GAP else centreX

	local sections: { Section } = {}
	local byKind: { [string]: Section } = {}
	local function add(
		kind: Kind,
		column: number,
		x: number,
		y: number,
		w: number,
		header: number,
		body: number,
		collapsible: boolean
	): Section
		local collapsed = collapsible and isCollapsed(input, kind)
		local section: Section = {
			kind = kind,
			column = column,
			x = x,
			y = y,
			w = w,
			header = header,
			body = if collapsed then 0 else body,
			collapsible = collapsible,
			collapsed = collapsed,
		}
		table.insert(sections, section)
		byKind[kind] = section
		return section
	end
	local function after(section: Section): number
		return section.y + section.header + section.body + SECTION_GAP
	end

	-- Left: the GROUND strip, CRAFTING or the block, ITEMS down to the band.
	local ground = add("ground", 1, 0, top, LEFT_W, 0, GROUND_H, false)
	local kind: Kind, body: number = blockSection(input)
	local block = add(kind, 1, 0, ground.y + GROUND_H + SECTION_GAP, LEFT_W, SECTION_HEADER, body, true)
	local jeiY = after(block)
	local jei = add("jei", 1, 0, jeiY, LEFT_W, SECTION_HEADER, math.max(0, columnH - jeiY - SECTION_HEADER), true)

	-- Centre: the character over HANDS.
	if wide then
		add("character", 2, centreX, 0, centreW, 0, columnH - SECTION_GAP - HANDS_H, false)
		add("hands", 2, centreX, columnH - HANDS_H, centreW, SECTION_HEADER, HANDS_H - SECTION_HEADER, false)
	end

	-- Right: the worn strip, BACKPACK, VANITY.
	local strip = add("equipment", 3, rightX, top, RIGHT_W, 0, stripHeight(input), false)
	local backpack =
		add("backpack", 3, rightX, strip.y + strip.body + SECTION_GAP, RIGHT_W, SECTION_HEADER, BACKPACK_H, true)
	if input.equipment then
		add("vanity", 3, rightX, after(backpack), RIGHT_W, SECTION_HEADER, VANITY_H, true)
	end

	local columns: { [number]: Rect } = { [1] = rect(0, 0, LEFT_W, columnH), [3] = rect(rightX, 0, RIGHT_W, columnH) }
	if wide then
		columns[2] = rect(centreX, 0, centreW, columnH)
	end

	-- The band: the quickbar centred when the status icons still fit at its right.
	local quickX = math.floor((width - QUICK_W) / 2)
	if width - (quickX + QUICK_W) < STATUS_W + 4 then
		quickX = 0
	end
	local status = if width - STATUS_W >= quickX + QUICK_W + BAND_GAP
		then rect(width - STATUS_W, height - STATUS_H, STATUS_W, STATUS_H)
		else nil
	-- The effect icons: the wider free stretch of the band beside the quickbar (left of it when it
	-- is centred, else between it and the status icons).
	local leftW = quickX - BAND_GAP
	local afterBar = quickX + QUICK_W + BAND_GAP
	local rightW = (if status then status.x - BAND_GAP else width) - afterBar
	local effects: Rect? = nil
	if leftW >= rightW and leftW >= EFFECTS_MIN_W then
		effects = rect(0, height - QUICK_H, leftW, QUICK_H)
	elseif rightW >= EFFECTS_MIN_W then
		effects = rect(afterBar, height - QUICK_H, rightW, QUICK_H)
	end

	return {
		mode = input.mode,
		width = width,
		height = height,
		columns = columns,
		tops = { rect(0, 0, LEFT_W, top), rect(rightX, 0, RIGHT_W, top) },
		titles = TITLES,
		sections = sections,
		byKind = byKind,
		jei = if jei.body > 0 then rect(0, jei.y + jei.header, LEFT_W, jei.body) else nil,
		drop = rect(0, ground.y, LEFT_W, GROUND_H),
		band = rect(0, height - QUICK_BAND, width, QUICK_BAND),
		quickbar = rect(quickX, height - QUICK_H, QUICK_W, QUICK_H),
		status = status,
		effects = effects,
		viewEffects = rect(0, height - QUICK_H, LEFT_W, QUICK_H),
	}
end

-- Is `kind` in `arrangement` and open (its slots live)?
function InventoryColumns.live(arrangement: Arrangement, kind: Kind): boolean
	local section = arrangement.byKind[kind]
	return section ~= nil and not section.collapsed
end

--[[
	How many of `slots[first .. last]` hold a stack: a section title's count (BACKPACK's inventory
	slots after the hotbar, a chest's 1 .. size). Read from the window's store, never from the
	drawn slots, so a collapsed section (whose slots are not live) still says what it holds.
]]
function InventoryColumns.used(slots: { [number]: any }, first: number, last: number): number
	local used = 0
	for slot = first, last do
		if slots[slot] ~= nil then
			used += 1
		end
	end
	return used
end

-- The recipe view's centre x in the root (GUI pixels): the centre and right columns' middle
-- (wide), the right column's (narrow).
function InventoryColumns.viewCentre(arrangement: Arrangement): number
	local right = arrangement.columns[3]
	local centre = arrangement.columns[2]
	local left = if centre then centre.x else right.x
	return (left + right.x + right.w) / 2
end

--[[ The scale ]]

-- The mode, scale, height, centre width and root position for `view` (see the header). Fills in
-- both inputs' mode, touch and top (and clears their height and centre width).
function InventoryColumns.place(view: View, wide: Input, narrow: Input): Placement
	local touch = view.touch
	local top = InventoryColumns.topHeader(touch, view.base)
	wide.mode, wide.touch, wide.top, wide.height, wide.centreW = "wide", touch, top, nil, nil
	narrow.mode, narrow.touch, narrow.top, narrow.height, narrow.centreW = "narrow", touch, top, nil, nil
	local lift = if touch then 0 else math.floor(INSET * view.h)
	local aw, ah = view.w, view.h - view.top - lift
	local wideW, wideH = InventoryColumns.minimum(wide)
	local narrowW, narrowH = InventoryColumns.minimum(narrow)
	local wideScale = GuiScale.fit(view.base, wideW, wideH, aw, ah, touch, wideH)
	local narrowScale = GuiScale.fit(view.base, narrowW, narrowH, aw, ah, touch, narrowH)
	local floor =
		math.min(view.base, if touch then InventoryColumns.MIN_WIDE_SCALE_TOUCH else InventoryColumns.MIN_WIDE_SCALE)
	local isWide = wideScale >= floor
	local scale = if isWide then wideScale else narrowScale
	local least = if isWide then wideH else narrowH
	local centreW = CENTRE_W
	if isWide and not touch then
		local room = math.floor((aw - 2 * math.floor(INSET * aw)) / scale) - SIDES_W
		centreW = math.clamp(room, CENTRE_W, CENTRE_MAX)
	end
	local margin = GuiScale.MARGIN
	local height = math.max(least, math.min(math.floor((ah - 2 * margin) / scale), MAX_HEIGHT))
	local width = if isWide then SIDES_W + centreW else NARROW_W
	-- (The room the root leaves: MARGIN of it below the root while there is that much, the rest
	-- above; the same y as top + MARGIN + the rest whenever both margins fit.)
	local free = ah - height * scale
	return {
		mode = if isWide then "wide" else "narrow",
		scale = scale,
		height = height,
		centreW = centreW,
		x = math.floor((aw - width * scale) / 2),
		y = view.top + math.floor(math.max(0, free - margin)),
	}
end

--[[ Slots, eyes, HANDS ]]

local function spot(store: Store, slot: number, x: number, y: number, big: boolean?, ghost: { string }?): Spot
	return { store = store, slot = slot, x = x, y = y, big = big == true, ghost = ghost }
end

--[[
	The slots of section `kind` in its body (`input`: the touch, equipment and the open block's
	panel): CRAFTING's 2 x 2 grid (container slots 2..5) and its result (1); the block's MenuLayout
	spots moved up BODY_CUT; the worn strip's armor (and window 0's accessories under it);
	BACKPACK's inventory 10..36; VANITY's armor and accessories (window 0); the GROUND strip's nine
	places (store "ground", nearest item first; no slots). Others have none.
]]
function InventoryColumns.spots(kind: Kind, input: Input): { Spot }
	local list: { Spot } = {}
	if kind == "craft" then
		for row = 0, 1 do
			for column = 0, 1 do
				table.insert(list, spot("container", 2 + row * 2 + column, 44 + column * PITCH, 3 + row * PITCH))
			end
		end
		table.insert(list, spot("container", Types.CRAFT_RESULT, 110, 12))
	elseif kind == "container" then
		local panel = input.panel
		if panel then
			for _, at in panel.slots do
				table.insert(list, spot("container", at.slot, at.x, at.y - BODY_CUT, at.big, at.ghost))
			end
		end
	elseif kind == "equipment" then
		for column = 0, Types.ARMOR_SIZE - 1 do
			table.insert(list, spot("armor", column + 1, 8 + column * PITCH, 3))
		end
		if input.equipment then
			for column = 0, Types.ACCESSORY_SIZE - 1 do
				table.insert(list, spot("accessory", column + 1, 8 + column * PITCH, 21))
			end
		end
	elseif kind == "backpack" then
		for row = 0, 2 do
			for column = 0, 8 do
				table.insert(list, spot("inventory", 10 + row * 9 + column, 8 + column * PITCH, 3 + row * PITCH))
			end
		end
	elseif kind == "vanity" then
		if input.equipment then
			for column = 0, Types.VANITY_ARMOR_SIZE - 1 do
				table.insert(list, spot("vanityArmor", column + 1, 8 + column * PITCH, 3))
			end
			for column = 0, Types.VANITY_ACCESSORY_SIZE - 1 do
				table.insert(list, spot("vanityAccessory", column + 1, 8 + column * PITCH, 21))
			end
		end
	elseif kind == "ground" then
		for column = 0, InventoryColumns.GROUND_SLOTS - 1 do
			table.insert(list, spot("ground", column + 1, 8 + column * PITCH, 3))
		end
	end
	return list
end

--[[
	The eye buttons of section `kind` in its body, in slot order: the worn strip's accessories'
	(window 0; a mouse's in each slot's top right corner as MenuLayout.armorEye, a finger's 16 x 18
	under each accessory) and VANITY's armor's (MenuLayout.armorEye). Others have none.
]]
function InventoryColumns.eyes(kind: Kind, input: Input): { Rect }
	local list: { Rect } = {}
	if not input.equipment then
		return list
	end
	if kind == "equipment" then
		for column = 0, Types.ACCESSORY_SIZE - 1 do
			local x = 8 + column * PITCH
			if input.touch then
				table.insert(list, rect(x, 40, 16, 18))
			else
				table.insert(list, MenuLayout.armorEye(x, 21, false))
			end
		end
	elseif kind == "vanity" then
		for column = 0, Types.VANITY_ARMOR_SIZE - 1 do
			table.insert(list, MenuLayout.armorEye(8 + column * PITCH, 3, input.touch))
		end
	end
	return list
end

-- The 18 x 18 frame (hit area) of a spot, or a large result's 26 x 26.
function InventoryColumns.frame(at: Spot): Rect
	if at.big then
		return rect(
			at.x - MenuLayout.BIG_INSET,
			at.y - MenuLayout.BIG_INSET,
			MenuLayout.BIG_FRAME,
			MenuLayout.BIG_FRAME
		)
	end
	return rect(at.x - 1, at.y - 1, PITCH, PITCH)
end

-- HANDS' body parts for a `w` wide centre (see the header's HandsLayout).
function InventoryColumns.hands(w: number): HandsLayout
	local item = Size.BIG_FACE
	return {
		bar = rect(0, 0, w, SECTION_HEADER),
		dot = rect(5, 5, Size.DOT, Size.DOT),
		item = rect(math.floor((w - item) / 2), 17, item, item),
		condition = rect(0, 43, w, 9),
		detail = rect(0, 52, w, 9),
	}
end

-- Where the block's section draws a MenuLayout panel's content: its y moved by this.
function InventoryColumns.containerOffset(): number
	return -BODY_CUT
end

--[[ Grid lines ]]

-- A spot's grid lines (inclusive): left, top, right, bottom.
local function lineFrame(at: Spot): (number, number, number, number)
	if at.big then
		return at.x - MenuLayout.BIG_INSET, at.y - MenuLayout.BIG_INSET, at.x + 20, at.y + 20
	end
	return at.x - 1, at.y - 1, at.x + 17, at.y + 17
end

type Interval = { a: number, b: number }

-- Sorts and merges touching or overlapping intervals.
local function merge(list: { Interval }): { Interval }
	table.sort(list, function(p: Interval, q: Interval): boolean
		return p.a < q.a
	end)
	local out: { Interval } = {}
	for _, interval in list do
		local last = out[#out]
		if last and interval.a <= last.b + 1 then
			last.b = math.max(last.b, interval.b)
		else
			table.insert(out, { a = interval.a, b = interval.b })
		end
	end
	return out
end

local function sortedKeys(map: { [number]: any }): { number }
	local keys: { number } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[[
	The 1 px grid lines around `spots` (body coordinates), as rects: every frame edge; the
	horizontal ones merged along each row, the vertical ones cut where a horizontal one crosses,
	so no pixel is painted twice (the slab shows every line at one alpha).
]]
function InventoryColumns.gridLines(spots: { Spot }): { Rect }
	local rows: { [number]: { Interval } } = {}
	local cols: { [number]: { Interval } } = {}
	local function addTo(map: { [number]: { Interval } }, at: number, a: number, b: number)
		local list = map[at]
		if list == nil then
			list = {}
			map[at] = list
		end
		table.insert(list, { a = a, b = b })
	end
	for _, at in spots do
		local left, top, right, bottom = lineFrame(at)
		addTo(rows, top, left, right)
		addTo(rows, bottom, left, right)
		addTo(cols, left, top, bottom)
		addTo(cols, right, top, bottom)
	end
	local rects: { Rect } = {}
	local merged: { [number]: { Interval } } = {}
	for _, y in sortedKeys(rows) do
		local list = merge(rows[y])
		merged[y] = list
		for _, interval in list do
			table.insert(rects, rect(interval.a, y, interval.b - interval.a + 1, 1))
		end
	end
	local function crossed(x: number, y: number): boolean
		local list = merged[y]
		if list then
			for _, interval in list do
				if x >= interval.a and x <= interval.b then
					return true
				end
			end
		end
		return false
	end
	for _, x in sortedKeys(cols) do
		for _, interval in merge(cols[x]) do
			local start: number? = nil
			for y = interval.a, interval.b + 1 do
				local open = y <= interval.b and not crossed(x, y)
				if open and start == nil then
					start = y
				elseif not open and start ~= nil then
					table.insert(rects, rect(x, start, 1, y - start))
					start = nil
				end
			end
		end
	end
	return rects
end

return InventoryColumns
