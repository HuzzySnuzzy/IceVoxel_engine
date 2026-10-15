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
	    the cold side in its own blues); temperature numbers take their zone's colour (`Zone`).

	Values that only builders need at a glance (tooltip delay, blink period, the HUD name's timing)
	are under `Time`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Drinks = require(Shared.ToughAsNails.Drinks)
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)

local MenuLayout = require(script.Parent.MenuLayout)

export type Rgba = { r: number, g: number, b: number, t: number }
export type Condition = { name: string, above: number, rgb: { number } }
export type Feedback = "fits" | "blocked" | "swap" | "combine" | "drop"
export type FaceState = "empty" | "filled" | "selected" | "locked"
export type Role = "top" | "section" | "body" | "small" | "tiny"
export type Weight = "Light" | "Regular" | "Bold"
export type HandsLines = { name: string, condition: Condition?, detail: string? }
-- What a carried stack is over (`feedback`): a slot, the drop strip (or outside), or nothing.
export type Over = "slot" | "drop" | "none"

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
	TipHead = rgba(0, 0, 0, 0.06),
	TipBody = rgba(0, 0, 0, 0.14),
	Liquid = rgba(0, 238, 255, 0.50),

	-- The status icons.
	Icon = rgba(220, 220, 220, 0),
	Warn = rgba(220, 220, 0, 0),
	Critical = rgba(220, 0, 0, 0),
	ColdWarn = rgba(0, 206, 209, 0),
	ColdCritical = rgba(30, 144, 220, 0),
	-- (The blinking levels' other colour.)
	Blink = rgba(255, 255, 255, 0),
	GlyphEmpty = rgba(220, 220, 220, 0.75),
	XpTrack = rgba(255, 255, 255, 0.75),
	XpFill = rgba(255, 255, 255, 0),
})

-- Temperature numbers by zone (-2 freezing .. 2 burning).
Theme.Zone = table.freeze({
	[-2] = rgba(112, 149, 211),
	[-1] = rgba(152, 217, 233),
	[0] = rgba(220, 220, 220),
	[1] = rgba(238, 130, 39),
	[2] = rgba(217, 44, 40),
} :: { [number]: Rgba })

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
	return if Theme.Text[role] * scale >= Theme.LIGHT_MIN then "Light" else "Regular"
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
	condition, and one detail: a durable item's "Durability 200 / 250", a canteen's "Sips 2 / 3", a
	stack's "x 32", an energy item's charge ("1.2 kJ"). nil for an empty hand. (Builds a table:
	call it when the held stack changed, not per frame.)
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
	if fraction and max then
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
