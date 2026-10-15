--!strict
--[[
	The inventory family's look in numbers: the dark, flat survival-game style of the inventory
	screen, the creative screen, JEI, the HUD's quickbar and status icons, the item tooltip and
	the carried stack. Pure: no Roblox APIs and no Color3 (Ui/Style's `Dayz` turns these tokens into
	Color3s, transparencies and Fonts once, at load), so the specs check every rule here
	(tests/spec/Theme). Other screens (Options, the skill tree, the title screen, chat, maps,
	WAILA) keep Ui/Style's Minecraft look.

	Rules every user keeps:

	  * Sizes are GUI pixels at GUI scale 1 (a UIScale multiplies them), except OUTLINE_PX, which is
	    screen pixels (`strokeThickness` turns it into a UIStroke thickness for a scale).
	  * Colours are `{ r, g, b, t }`: 0..255 channels and the transparency t = 1 - alpha, as
	    BackgroundTransparency / TextTransparency take it. Keys are the names builders use: nothing
	    outside this module writes a colour of its own for something this module names.
	  * Text is Roboto (built into Roblox), in three weights (`weight`: Light only where it is at
	    least 14 screen pixels tall, thinner below that is spindly); headers and section titles are
	    upper case (`caps`, `sectionTitle`). Counts use fixed digit widths (`count`, `countWidth`),
	    so a count box never has to measure its text.
	  * A slot's face has four states (`face`): empty (no fill: the grid's slab shows), filled
	    (white at 0.04), selected (the quickbar's olive) and locked (a closed accessory slot's
	    shade). Only the slot widgets and the quickbar paint faces (Style.Dayz.paintFace).
	  * Item pictures are drawn darker than they are (`ItemTint`), as cells of a dark inventory.
	  * Condition: a durable item's durability left (Ui/MenuLayout.wear) falls through five levels,
	    Pristine to Ruined (`condition`), each with a colour for its dot and bar and a word; no cell
	    is tinted by it. A canteen's durability is its sips: a quantity, so it has no condition.
	  * Drag feedback only colours outlines (`feedback`, `FeedbackColour`, at FEEDBACK_T): green
	    fits, red blocked, light blue swaps, orange combines, white the drop strip.
	  * The status icons are white when fine, yellow, then red, then blinking (Icon, Warn, Critical;
	    the cold side in its own blues), the whole silhouette: the part lit in full, the emptied
	    part at GLYPH_ALARM_T (faint GlyphEmpty while fine); temperature numbers take their zone's
	    colour (`Zone`).
	  * Headers are not quite flat (`Gradient`): the grey top headers darken a little towards their
	    bottom edge and the black section bars thin out towards theirs, each averaging its token's
	    value, so a header reads as the token says from a distance.
	  * The item tooltip (`tip`): a dark header (a condition dot, the name, the condition word, the
	    count) over a dark body (the item's picture on the left, a liquid pill and the tooltip's
	    lines on the right, wrapped), between Tip.MIN_W and Tip.MAX_W wide; a tooltip of no item
	    (a fluid, a gauge, a button of the recipe view) is its first line as a header over the
	    rest. One layout per thing hovered: the owner calls `tip` only when what it shows changed.
	    A stack's count is not part of that: the header keeps room for the widest the count may
	    read (`countRoom`), so a count that changes under the pointer is rewritten in place
	    (`countAt` says which text) and the box keeps its size.

	Values that only builders need at a glance (tooltip delay, blink period, the HUD name's timing)
	are under `Time`; the look's few fixed words (a ground item's hint, the empty GROUND strip) under
	`Words`. The quickbar's key numbers show only off touch and from NUMBER_MIN_PX screen pixels of
	text (`numbersShown`), on the HUD and in the inventory's band alike.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Drinks = require(Shared.ToughAsNails.Drinks)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local WeaponState = require(Shared.Weapons.WeaponState)

local MenuLayout = require(script.Parent.MenuLayout)
local TextWrap = require(script.Parent.TextWrap)

export type Rgba = { r: number, g: number, b: number, t: number }
export type Condition = { name: string, above: number, rgb: { number } }
export type Feedback = "fits" | "blocked" | "swap" | "combine" | "drop"
export type FaceState = "empty" | "filled" | "selected" | "locked"
export type Role = "top" | "section" | "body" | "small" | "tiny"
export type Weight = "Light" | "Regular" | "Bold"
export type HandsLines = { name: string, condition: Condition?, detail: string? }
-- What a carried stack is over (`feedback`): a slot, the drop strip (or outside), or nothing.
export type Over = "slot" | "drop" | "none"
-- A rectangle in GUI pixels.
export type Rect = { x: number, y: number, w: number, h: number }
-- A line of the item tooltip: its text and its colour's key (Theme.Colour).
export type TipLine = { text: string, colour: string }
-- One text the item tooltip draws: where, in which role, colour key and alignment.
export type TipText = {
	text: string,
	colour: string,
	role: Role,
	align: "left" | "right" | "center",
	x: number,
	y: number,
	w: number,
	h: number,
}
-- What an item tooltip shows (`tip`).
export type TipInput = {
	-- The item's name (or, without a picture, the tooltip's first line) and its colour key.
	name: string,
	nameColour: string?,
	-- The item's condition (its dot and word), its count ("32 / 64") and its liquid (the pill).
	condition: Condition?,
	count: string?,
	-- The widest the count may read while this tooltip shows ("88 / 64"): the header keeps room
	-- for it, so the box keeps its width as the count changes (nil: the count's own width).
	countRoom: string?,
	liquid: string?,
	-- An item's tooltip (a picture, the two-row header); false: a plain one (a fluid, a gauge).
	picture: boolean,
	-- The body's lines, unwrapped ("" a small gap).
	lines: { TipLine },
}
-- The item tooltip laid out (GUI pixels): its size, the header's height (the body is below it),
-- the dot, the picture and the pill (when shown), every text, and which of them is the count (its
-- index in `texts`: the owner may rewrite that one's text in place, within the room kept for it).
export type TipLayout = {
	w: number,
	h: number,
	head: number,
	dot: Rect?,
	picture: Rect?,
	pill: Rect?,
	texts: { TipText },
	countAt: number?,
}
-- Measures `text` at TextSize `size` (GUI pixels).
export type Measure = (text: string, size: number) -> number

local Theme = {}

local function rgba(r: number, g: number, b: number, t: number?): Rgba
	return table.freeze({ r = r, g = g, b = b, t = t or 0 })
end

--[[ Fonts and text ]]

-- Font families by name (Style.Dayz.face makes the Fonts): all text is Roboto; the condensed
-- face is there for text that must fit a fixed width.
Theme.Font = table.freeze({
	family = "Roboto",
	condensed = "RobotoCondensed",
})

-- TextSize by role at GUI scale 1: top headers (bold), section titles, item names, small lines and
-- the tiny quickbar numbers.
Theme.Text = table.freeze({
	top = 8,
	section = 7,
	body = 8,
	small = 7,
	tiny = 6,
} :: { [string]: number })

-- Line pitch of stacked text (GUI pixels).
Theme.Line = table.freeze({ body = 10, small = 9 })

-- Light text below this many screen pixels is too thin: it is drawn Regular.
Theme.LIGHT_MIN = 14

-- The quickbar's key numbers show only from this many screen pixels of text (the tiny role at the
-- scale: `numbersShown`).
Theme.NUMBER_MIN_PX = 8

--[[ Geometry (GUI pixels) ]]

Theme.Size = table.freeze({
	-- The grey column headers (touch: taller, InventoryColumns.topHeader).
	TOP_HEADER = 14,
	-- The black section bars, and the HANDS name bar.
	SECTION_HEADER = 14,
	SECTION_GAP = 2,
	COLUMN_GAP = 6,
	-- The inventory's quickbar band under its columns (4 + the 22 bar).
	QUICK_BAND = 26,
	-- A slot's face inside its grid lines, the slot pitch, a grid line: a slot's lines are at x - 1
	-- and x + 17 (shared with its neighbour), its face x .. x + 16.
	CELL = 17,
	PITCH = 18,
	LINE = 1,
	-- A large result slot's face (lines at x - 5 and x + 20: MenuLayout's 26 frame).
	BIG_FACE = 24,
	-- A count box's side padding (its height, text size and digit width: `count`).
	COUNT_PAD = 1,
	-- The condition / quantity / energy bar in the 16 x 16 item.
	BAR = table.freeze({ x = 1, y = 14, w = 14, h = 1 }),
	-- The condition dot.
	DOT = 4,
	-- Top header buttons (touch: the header's height square), their glyph 8 x 8 centred.
	HEADER_BUTTON = 12,
	HEADER_GLYPH = 8,
	-- The picture at a section header's left, and the minus / plus at its right (3 px in).
	HEADER_PICTURE = 12,
	HEADER_TOGGLE = 8,
	HEADER_TOGGLE_INSET = 3,
	-- The HUD's item-in-hands box.
	NAME_H = 11,
	-- The item tooltip's picture.
	TIP_PICTURE = 40,
	-- Screen pixels of every hover, selection, feedback and drop outline.
	OUTLINE_PX = 2,
	-- Notifier and badge silhouettes on screen; masks are rendered at MASK x MASK px.
	GLYPH = 11,
	BADGE = 9,
	MASK = 48,
	-- A scrollbar's thumb.
	THUMB_H = 15,
	-- Touch top headers: at least this tall (InventoryColumns.topHeader: HudLayout's TOUCH_TARGET
	-- screen pixels at the base scale).
	TOUCH_HEADER_MIN = 22,
	-- The HUD's item-in-hands box: its side padding, the gap after the condition dot, the gap
	-- before a Thermometer's reading and the gaps around the reading's arrow.
	NAME_PAD = 3,
	NAME_DOT_GAP = 3,
	READING_GAP = 5,
	READING_ARROW_GAP = 2,
	-- The dark strips behind the side columns reach this far past them (wide).
	STRIP_REACH = 3,
	-- A gauge's bar (a furnace's progress and fuel, a machine's energy and progress), the crafting
	-- chevron and the recipe view's padlock on a locked result.
	GAUGE = 2,
	CHEVRON = 8,
	PADLOCK = 8,
	-- The room a block's status line keeps at its right (the energy bar's column).
	LINE_ROOM = 16,
	-- A worn slot's silhouette (at GHOST_AT, GHOST square, in the 18 x 18 slot button), VANITY's
	-- corner mark and a closed accessory slot's padlock (at LOCK_AT, LOCK square).
	GHOST_AT = 2,
	GHOST = 14,
	GHOST_MARK = 3,
	LOCK_AT = 4,
	LOCK = 10,
})

--[[ Colours ]]

Theme.Colour = table.freeze({
	-- Panels and bodies.
	TopHeader = rgba(128, 128, 128, 0.20),
	TopHeaderText = rgba(0, 0, 0, 0),
	SectionHeader = rgba(0, 0, 0, 0.20),
	SectionHeaderText = rgba(255, 255, 255, 0),
	SectionBody = rgba(0, 0, 0, 0.29),
	StripBody = rgba(80, 80, 80, 0.35),
	GroundBody = rgba(120, 120, 120, 0.35),
	HandsBody = rgba(50, 50, 50, 0.61),
	Panel = rgba(0, 0, 0, 0.45),
	Hairline = rgba(255, 255, 255, 0.85),
	GridLine = rgba(255, 255, 255, 0.93),
	Divider = rgba(255, 255, 255, 0.71),
	Backdrop = rgba(0, 0, 0, 0.85),
	BackdropTouch = rgba(0, 0, 0, 0.70),
	-- (t at the corners; 1 inside: Masks.vignette.)
	Vignette = rgba(0, 0, 0, 0.30),
	SideStrip = rgba(0, 0, 0, 0.90),

	-- Cells, slots, gauges.
	Cell = rgba(255, 255, 255, 1),
	CellFilled = rgba(255, 255, 255, 0.96),
	QuickCell = rgba(80, 80, 80, 0.53),
	Selected = rgba(110, 152, 13, 0.75),
	Outline = rgba(255, 255, 255, 0),
	Ghost = rgba(255, 255, 255, 0.80),
	GhostVanity = rgba(255, 255, 255, 0.88),
	GhostMark = rgba(255, 255, 255, 0.50),
	LockShade = rgba(0, 0, 0, 0.40),
	Lock = rgba(255, 255, 255, 0.50),
	CountBox = rgba(0, 0, 0, 0.22),
	BarTrack = rgba(0, 0, 0, 0.45),
	QuantityTrack = rgba(255, 255, 255, 0.75),
	Quantity = rgba(255, 255, 255, 0),
	Fuel = rgba(255, 165, 0, 0),
	TankTrack = rgba(0, 0, 0, 0.29),
	Chevron = rgba(255, 255, 255, 0.50),
	-- ImageColor3 of every item picture in this look (t unused).
	ItemTint = rgba(179, 179, 179, 0),
	QuickNumberBox = rgba(0, 0, 0, 0),
	QuickNumberBoxEmpty = rgba(0, 0, 0, 0.61),
	QuickNumberLine = rgba(255, 255, 255, 0),
	QuickNumberLineEmpty = rgba(255, 255, 255, 0.61),
	QuickNumberText = rgba(255, 255, 255, 0),
	QuickNumberTextEmpty = rgba(255, 255, 255, 0.22),

	-- Text and controls.
	Text = rgba(255, 255, 255, 0),
	TextSoft = rgba(220, 220, 220, 0),
	TextMuted = rgba(160, 160, 160, 0),
	TextDisabled = rgba(255, 255, 255, 0.61),
	Warning = rgba(255, 80, 80, 0),
	Placeholder = rgba(125, 127, 133, 0),
	Focus = rgba(215, 13, 17, 0),
	Button = rgba(0, 0, 0, 0.40),
	ButtonHover = rgba(255, 255, 255, 0.85),
	Field = rgba(0, 0, 0, 0.30),
	-- A scrollbar's thumb, while it can scroll and while it cannot.
	ThumbActive = rgba(220, 220, 220, 0.30),
	Thumb = rgba(220, 220, 220, 0.80),
	TipHead = rgba(0, 0, 0, 0.06),
	TipBody = rgba(0, 0, 0, 0.14),
	Liquid = rgba(0, 238, 255, 0.50),
	-- Text outlines over the world: badge counts and the hovered effect's line, and the fainter one
	-- of the HUD's item name (readable over a bright sky).
	TextStroke = rgba(0, 0, 0, 0.40),
	TextStrokeSoft = rgba(0, 0, 0, 0.75),
	-- The red over a missing ingredient in the recipe view (Warning, see-through).
	Missing = rgba(255, 80, 80, 0.60),

	-- The status icons.
	Icon = rgba(220, 220, 220, 0),
	Warn = rgba(220, 220, 0, 0),
	Critical = rgba(220, 0, 0, 0),
	ColdWarn = rgba(0, 206, 209, 0),
	ColdCritical = rgba(30, 144, 220, 0),
	-- (The blinking levels' other colour.)
	Blink = rgba(255, 255, 255, 0),
	-- The emptied part of a glyph while its stat is fine (from level 3 the emptied part takes
	-- the level's colour at GLYPH_ALARM_T instead), and a whole glyph with nothing to say (mana
	-- full and idle: lit through, faint).
	GlyphEmpty = rgba(220, 220, 220, 0.75),
	GlyphIdle = rgba(220, 220, 220, 0.55),
	XpTrack = rgba(255, 255, 255, 0.75),
	XpFill = rgba(255, 255, 255, 0),

	-- The rest of the HUD: the attack indicator's rising fill, an ambient effect's pale blue rim,
	-- and the frost and heat at the screen's edges (t unused: their strength sets it).
	AttackFill = rgba(255, 255, 255, 0.35),
	AmbientRim = rgba(150, 200, 230, 0.40),
	Frost = rgba(205, 235, 255, 0),
	Heat = rgba(255, 96, 32, 0),
})

--[[
	The headers' faint gradients (top to bottom). The grey top headers are TOP_GREY multiplied from
	TOP_FROM down to TOP_TO (a mean of TopHeader's 128); the black section bars go from SECTION_FROM
	to SECTION_TO transparency (a mean of SectionHeader's 0.20).
]]
Theme.Gradient = table.freeze({
	TOP_GREY = 141,
	TOP_FROM = 1,
	TOP_TO = 0.82,
	SECTION_FROM = 0.12,
	SECTION_TO = 0.28,
})

-- Temperature numbers by zone (-2 freezing .. 2 burning).
Theme.Zone = table.freeze({
	[-2] = rgba(112, 149, 211),
	[-1] = rgba(152, 217, 233),
	[0] = rgba(220, 220, 220),
	[1] = rgba(238, 130, 39),
	[2] = rgba(217, 44, 40),
} :: { [number]: Rgba })

--[[
	The emptied part of a status glyph at a warning level or worse (3..5): the level's colour (and
	its blink) at this transparency, so the alarm shows however little of the glyph is lit.
]]
Theme.GLYPH_ALARM_T = 0.5

--[[ Drag feedback (outlines only) ]]

Theme.FEEDBACK_T = 0.41
Theme.FeedbackColour = table.freeze({
	fits = rgba(1, 255, 1, Theme.FEEDBACK_T),
	blocked = rgba(255, 1, 1, Theme.FEEDBACK_T),
	swap = rgba(135, 206, 250, Theme.FEEDBACK_T),
	combine = rgba(255, 165, 0, Theme.FEEDBACK_T),
	drop = rgba(255, 255, 255, Theme.FEEDBACK_T),
} :: { [Feedback]: Rgba })

--[[
	What a carried stack would do where it is, for the outline colours. Positional so nothing is
	built per frame: `carrying` a stack, `over` a slot / the drop strip / nothing, that slot
	`empty`, the stack `allowed` there (Menu.mayPlace), the slot holding the `same` stack
	(Menu.stacksMatch), `room` for more of it (under Menu.maxStackFor; on a result slot: the cursor
	taking the result whole), and the slot a `result` (Menu.isResultSlot). nil: no feedback.
]]
function Theme.feedback(
	carrying: boolean,
	over: Over,
	empty: boolean,
	allowed: boolean,
	same: boolean,
	room: boolean,
	result: boolean
): Feedback?
	if not carrying or over == "none" then
		return nil
	elseif over == "drop" then
		return "drop"
	elseif result then
		return if same and room then "combine" else "blocked"
	elseif not allowed then
		return "blocked"
	elseif empty then
		return "fits"
	elseif same then
		return if room then "combine" else "blocked"
	end
	return "swap"
end

--[[ Condition ]]

-- Best to worst; a fraction of durability left above `above` is that level (the last catches the rest).
Theme.CONDITIONS = table.freeze({
	table.freeze({ name = "Pristine", above = 0.80, rgb = table.freeze({ 64, 255, 0 }) }),
	table.freeze({ name = "Worn", above = 0.60, rgb = table.freeze({ 191, 255, 0 }) }),
	table.freeze({ name = "Damaged", above = 0.40, rgb = table.freeze({ 255, 255, 0 }) }),
	table.freeze({ name = "Badly damaged", above = 0.20, rgb = table.freeze({ 255, 191, 0 }) }),
	table.freeze({ name = "Ruined", above = -math.huge, rgb = table.freeze({ 255, 0, 0 }) }),
} :: { Condition })

-- The condition dot's transparency (the level's colour at half).
Theme.DOT_T = 0.5

--[[
	The condition of `fraction` durability left (Ui/MenuLayout.wear; 1 = undamaged): nil for items
	without durability (nil) and for sips (a canteen's durability is a quantity).
]]
function Theme.condition(fraction: number?, sips: boolean?): Condition?
	if fraction == nil or sips or fraction ~= fraction then
		return nil
	end
	for _, level in Theme.CONDITIONS do
		if fraction > level.above then
			return level
		end
	end
	return Theme.CONDITIONS[#Theme.CONDITIONS]
end

--[[ Text helpers ]]

function Theme.caps(text: string): string
	return string.upper(text)
end

-- A section's title: its name in capitals, with "(used/total)" when both are given.
function Theme.sectionTitle(name: string, used: number?, total: number?): string
	local title = Theme.caps(name)
	if used and total then
		return `{title} ({used}/{total})`
	end
	return title
end

--[[
	The weight a text of `role` is drawn in at GUI `scale`: top headers bold, item names regular,
	the smaller roles light when they come out at least LIGHT_MIN screen pixels tall.
]]
function Theme.weight(role: Role, scale: number): Weight
	if role == "top" then
		return "Bold"
	elseif role == "body" then
		return "Regular"
	end
	return Theme.thin(Theme.Text[role], scale)
end

-- Light for text of TextSize `size` that comes out at least LIGHT_MIN screen pixels tall at GUI
-- `scale`, else Regular (a count box's digits, the small roles).
function Theme.thin(size: number, scale: number): Weight
	return if size * scale >= Theme.LIGHT_MIN then "Light" else "Regular"
end

--[[
	A count box at GUI `scale`: its height, the TextSize and the width of a digit (GUI pixels). Under
	2.5 the box is 7 tall with 7 px text, from 2.5 on 6 and 6 (the same text on screen, less of the
	cell covered).
]]
function Theme.count(scale: number): (number, number, number)
	if scale >= 2.5 then
		return 6, 6, 3
	end
	return 7, 7, 4
end

-- A count box's width for `text` with digits `digit` wide.
function Theme.countWidth(text: string, digit: number): number
	return 2 * Theme.Size.COUNT_PAD + digit * #text
end

--[[ Faces and outlines ]]

-- A slot face's state: its colour key and transparency.
function Theme.face(state: FaceState): (string, number)
	if state == "filled" then
		return "CellFilled", Theme.Colour.CellFilled.t
	elseif state == "selected" then
		return "Selected", Theme.Colour.Selected.t
	elseif state == "locked" then
		return "LockShade", Theme.Colour.LockShade.t
	end
	return "Cell", Theme.Colour.Cell.t
end

--[[
	Does a UIScale multiply a UIStroke's FixedSize thickness? (Measured in Studio; while true,
	`strokeThickness` divides OUTLINE_PX by the scale so outlines stay OUTLINE_PX screen pixels.)
]]
Theme.STROKE_FOLLOWS_UISCALE = true

-- The UIStroke thickness that shows OUTLINE_PX screen pixels at GUI `scale`.
function Theme.strokeThickness(scale: number, follows: boolean): number
	if follows and scale > 0 then
		return Theme.Size.OUTLINE_PX / scale
	end
	return Theme.Size.OUTLINE_PX
end

--[[
	A quickbar number box in its 18 x 18 cell: x, y, w, h. Over an item it sits in the top right
	corner; an empty slot's, fainter, in the middle.
]]
function Theme.quickNumber(occupied: boolean): (number, number, number, number)
	if occupied then
		return 12, 0, 6, 6
	end
	return 6, 6, 6, 6
end

--[[
	Do the quickbar's number boxes show at GUI `scale` (the HUD's quickbar and the inventory's band)?
	Not on a `touch` screen (it has no number keys), and not while the tiny text would come out under
	NUMBER_MIN_PX screen pixels.
]]
function Theme.numbersShown(scale: number, touch: boolean): boolean
	return not touch and Theme.Text.tiny * scale >= Theme.NUMBER_MIN_PX
end

--[[ Tooltips ]]

local TOOLTIP_COLOURS: { [string]: string } = {
	white = "Text",
	gray = "TextMuted",
	blue = "TextSoft",
	darkGreen = "TextSoft",
	red = "Warning",
	lore = "TextMuted",
}

-- The colour key of a tooltip line's colour name (Shared/Items/Tooltip); unknown names are Text.
function Theme.tooltipColour(name: string): string
	return TOOLTIP_COLOURS[name] or "Text"
end

-- The water drinks (the liquid they hold is water; a dirty one's is dirty water).
local WATER: { [any]: boolean } = {
	[Drinks.DIRTY] = true,
	[Drinks.PURIFIED] = true,
	[Drinks.DIRTY_BOWL] = true,
	[Drinks.PURIFIED_BOWL] = true,
}

--[[
	The liquid an item holds, for the tooltip's pill: a full bucket's fluid ("Lava"), "Dirty Water"
	or "Water" for the water drinks (bottles, canteens, bowls); nil for anything else (empty
	containers, teas, potions and sodas too).
]]
function Theme.liquid(item: number?): string?
	if item == nil then
		return nil
	end
	local fluid = Fluids.ofBucket(item)
	if fluid ~= 0 then
		return Fluids.name(fluid)
	end
	local drink = Drinks.of(item)
	if drink and WATER[drink] then
		return if Drinks.isDirty(item) then "Dirty Water" else "Water"
	end
	return nil
end

--[[
	The texts of the held item's box (the inventory's HANDS, the HUD's name): its name, its
	condition, and one detail: a firearm's or a magazine's rounds (Shared/Weapons/WeaponState
	.detail: "12 / 15 +1", "No magazine", "JAMMED"), else a durable item's "Durability 200 / 250", a
	canteen's "Sips 2 / 3", a stack's "x 32", an energy item's charge ("1.2 kJ"). nil for an empty
	hand. (Builds a table: call it when the held stack changed, not per frame.)
]]
function Theme.handsLines(stack: Items.Stack?): HandsLines?
	if stack == nil or stack.item == nil then
		return nil
	end
	local item = stack.item
	local fraction, sips = MenuLayout.wear(item, stack.damage)
	local detail: string? = nil
	local def = Items.get(item)
	local max = def and def.durability
	local weapon = WeaponState.detail(stack)
	if weapon then
		detail = weapon
	elseif fraction and max then
		local damage = Items.cleanDamage(stack.damage) or 0
		local left = math.max(0, max - damage)
		detail = if sips then `Sips {left} / {max}` else `Durability {left} / {max}`
	elseif stack.count > 1 and Items.maxStack(item) > 1 then
		detail = `x {stack.count}`
	else
		local energy = Items.dataNumber(stack.data, "energy")
		if energy and energy == energy and energy > 0 then
			detail = Items.formatEnergy(energy)
		end
	end
	return { name = Items.displayName(item), condition = Theme.condition(fraction, sips), detail = detail }
end

--[[ The item tooltip ]]

Theme.Tip = table.freeze({
	-- An item tooltip's width: its contents' within these.
	MIN_W = 140,
	MAX_W = 220,
	-- An item tooltip's header (the name over the condition word and the count, each row ROW_H
	-- tall at NAME_Y and WORD_Y), and a plain tooltip's (its first line).
	HEAD = 18,
	PLAIN_HEAD = 14,
	NAME_Y = 1,
	WORD_Y = 9,
	ROW_H = 8,
	-- The padding round everything, the condition dot's top left, and the name's left edge after
	-- the dot (PAD without one).
	PAD = 4,
	DOT_X = 4,
	DOT_Y = 7,
	NAME_X = 11,
	-- Between the condition word and the count.
	GAP = 6,
	-- The body's text column: from TEXT_X (right of the picture) to PAD from the right edge.
	TEXT_X = 48,
	-- The liquid pill: its height, its text's side padding and the gap under it.
	PILL_H = 9,
	PILL_PAD = 3,
	PILL_GAP = 2,
	-- An empty line's gap between blocks of lines.
	BLANK = 4,
	-- The body's least height: the picture and its padding.
	BODY_MIN = 48,
})

-- The rows of `lines` wrapped to `width` into `texts`, from `y`; returns the y after the last row.
local function tipRows(
	texts: { TipText },
	lines: { TipLine },
	x: number,
	y: number,
	width: number,
	measure: Measure
): number
	local tip = Theme.Tip
	local size, pitch = Theme.Text.small, Theme.Line.small
	local gap, added = false, 0
	local measureSmall = function(text: string): number
		return measure(text, size)
	end
	for _, line in lines do
		if line.text == "" then
			-- (A gap only between rows: none at the top or the bottom.)
			gap = added > 0
			continue
		end
		for _, row in TextWrap.wrap(line.text, width, measureSmall) do
			if gap then
				y += tip.BLANK
				gap = false
			end
			added += 1
			table.insert(
				texts,
				{
					text = row,
					colour = line.colour,
					role = "small",
					align = "left",
					x = x,
					y = y,
					w = width,
					h = pitch,
				} :: TipText
			)
			y += pitch
		end
	end
	return y
end

-- The widest of `lines` unwrapped at the small size.
local function widest(lines: { TipLine }, measure: Measure): number
	local width = 0
	for _, line in lines do
		if line.text ~= "" then
			width = math.max(width, measure(line.text, Theme.Text.small))
		end
	end
	return width
end

--[[
	The item tooltip of `input` laid out, measuring text with `measure` (see the header). An item's:
	the header (HEAD tall: with a condition, its dot at DOT_X, DOT_Y and the name from NAME_X; the
	name on the top row and the condition word and the count, right-aligned with room for its
	countRoom, on the bottom one, or the name alone centred down the header), then the body: the
	picture at PAD, PAD under the header, and from TEXT_X the liquid pill and the lines, wrapped to
	the column; the body is at least BODY_MIN tall. A plain tooltip's: the name in a PLAIN_HEAD
	header, the lines under it.
]]
function Theme.tip(input: TipInput, measure: Measure): TipLayout
	local tip = Theme.Tip
	local pad = tip.PAD
	local body, small = Theme.Text.body, Theme.Text.small
	local texts: { TipText } = {}
	local nameColour = input.nameColour or "Text"
	if not input.picture then
		local head = tip.PLAIN_HEAD
		local need = math.max(measure(input.name, body), widest(input.lines, measure)) + 2 * pad
		local w = math.min(math.ceil(need), tip.MAX_W)
		table.insert(
			texts,
			{
				text = input.name,
				colour = nameColour,
				role = "body",
				align = "left",
				x = pad,
				y = 0,
				w = w - 2 * pad,
				h = head,
			} :: TipText
		)
		local bottom = tipRows(texts, input.lines, pad, head + pad, w - 2 * pad, measure)
		local h = if #texts > 1 then bottom + pad else head
		return { w = w, h = h, head = head, dot = nil, picture = nil, pill = nil, texts = texts, countAt = nil }
	end
	local condition = input.condition
	local nameX = if condition then tip.NAME_X else pad
	local word = if condition then condition.name else nil
	local count = input.count
	-- The width the contents ask for, unwrapped.
	local need = nameX + measure(input.name, body) + pad
	local second = 0
	if word then
		second += measure(word, small)
	end
	if count then
		local room = input.countRoom
		local countW = measure(count, small)
		if room then
			countW = math.max(countW, measure(room, small))
		end
		second += countW + (if word then tip.GAP else 0)
	end
	need = math.max(need, nameX + second + pad)
	local column = widest(input.lines, measure)
	local liquid = input.liquid
	if liquid then
		column = math.max(column, measure(liquid, small) + 2 * tip.PILL_PAD)
	end
	need = math.max(need, tip.TEXT_X + column + pad)
	local w = math.clamp(math.ceil(need), tip.MIN_W, tip.MAX_W)
	-- The header.
	local head = tip.HEAD
	local rows = word ~= nil or count ~= nil
	table.insert(
		texts,
		{
			text = input.name,
			colour = nameColour,
			role = "body",
			align = "left",
			x = nameX,
			y = if rows then tip.NAME_Y else 0,
			w = w - nameX - pad,
			h = if rows then tip.ROW_H else head,
		} :: TipText
	)
	if word then
		table.insert(
			texts,
			{
				text = word,
				colour = "Text",
				role = "small",
				align = "left",
				x = nameX,
				y = tip.WORD_Y,
				w = w - nameX - pad,
				h = tip.ROW_H,
			} :: TipText
		)
	end
	local countAt: number? = nil
	if count then
		countAt = #texts + 1
		table.insert(
			texts,
			{
				text = count,
				colour = "Text",
				role = "small",
				align = "right",
				x = nameX,
				y = tip.WORD_Y,
				w = w - nameX - pad,
				h = tip.ROW_H,
			} :: TipText
		)
	end
	local dot: Rect? = nil
	if condition then
		dot = { x = tip.DOT_X, y = tip.DOT_Y, w = Theme.Size.DOT, h = Theme.Size.DOT }
	end
	-- The body.
	local picture = Theme.Size.TIP_PICTURE
	local x, width = tip.TEXT_X, w - tip.TEXT_X - pad
	local y = head + pad
	local pill: Rect? = nil
	if liquid then
		pill = { x = x, y = y, w = width, h = tip.PILL_H }
		table.insert(
			texts,
			{
				text = liquid,
				colour = "Text",
				role = "small",
				align = "center",
				x = x,
				y = y,
				w = width,
				h = tip.PILL_H,
			} :: TipText
		)
		y += tip.PILL_H + tip.PILL_GAP
	end
	local before = #texts
	local bottom = tipRows(texts, input.lines, x, y, width, measure)
	if #texts == before and liquid then
		-- (No line under the pill: no gap under it either.)
		bottom -= tip.PILL_GAP
	end
	local bodyHeight = math.max(tip.BODY_MIN, bottom + pad - head)
	return {
		w = w,
		h = head + bodyHeight,
		head = head,
		dot = dot,
		picture = { x = pad, y = head + pad, w = picture, h = picture },
		pill = pill,
		texts = texts,
		countAt = countAt,
	}
end

--[[ Words ]]

-- The look's fixed words: a ground item's tooltip line, and the GROUND strip's empty-state text.
Theme.Words = table.freeze({
	GROUND_HINT = "Walk over it to pick it up",
	DROP_HERE = "Drop here",
})

--[[ Timing ]]

Theme.Time = table.freeze({
	-- An item tooltip shows once the pointer stayed on the same thing this long (mouse).
	TOOLTIP_DELAY = 0.25,
	-- The status icons' blink period.
	BLINK = 0.25,
	-- The HUD's item name: shown, then fading.
	NAME = 2,
	NAME_FADE = 0.5,
	-- A notifier's flash on damage.
	FLASH = 1,
})

return Theme
