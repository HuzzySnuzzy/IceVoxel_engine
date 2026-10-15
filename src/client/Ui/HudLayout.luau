--!strict
--[[
	Where the HUD's pieces go (pure: numbers in, rectangles out, so the tests place every screen
	and every GUI Scale choice): the quickbar's canvas at the bottom centre and its cells, the
	status icons (Ui/StatusCluster) at the bottom right on the quickbar's base line, and the shared
	top right corner: the minimap with its coordinates line (or the touch "Map" button while the
	minimap is off) and the zombie apocalypse's day line under them, the toasts under that
	(Minecraft's ToastComponent: the Now Playing toast in the first slot, the "World saved" toast
	in it or under it, the blood moon's notices under those), the status effect icons (Minecraft's
	Gui.renderEffects: the top right) and the saving icon at the bottom right; WAILA keeps out of
	them, and right of the F3 text.

	Everything is in screen pixels: (0, 0) the screen's top left, `width` x `height` the camera's
	viewport. Sizes are GUI pixels (below) times the GUI scale, so the corner grows and shrinks
	with the GUI Scale setting like the rest of the HUD (the minimap ignored it before: 192 pixels
	whatever the scale, and everything under it was pinned to those pixels). The rules:

	  area      the device's safe area (notches: `insets`), below Roblox's top bar (`insets.bar`,
	            from the screen's top), MARGIN GUI pixels inside it; everything placed stays in it
	            or is dropped (nil) when it cannot fit.
	  lift      on a PC the bottom of the HUD sits `lift` (LIFT, 5 % of the screen's height) above
	            the safe area's bottom, as a survival game's 90 % safe frame keeps its quickbar and
	            status icons off the screen's edge, and the status icons keep as far from the right
	            edge. Touch screens keep the bottom (the thumbs are there): no lift. What Minecraft
	            places a fixed height over its hotbar (Ui/Chat's lines at 40 GUI pixels and its
	            overlay message at 64 to 72) goes up by the same lift (`lifted`), or the lifted
	            quickbar and item-in-hands box would run into it at the smaller GUI scales (a
	            1920 x 1080 screen at GUI Scale 1: the bar 55 to 77 screen pixels up, the overlay
	            message 64 to 72).
	  canvas    Ui/Hud's canvas (CANVAS: 182 x 46 GUI pixels, 230 wide with the touch buttons
	            beside the quickbar; `hud`: centred at the bottom, one pixel and the lift above the
	            safe area's bottom, at the scale given, which is at most the HUD's own): the
	            quickbar at QUICK.bar (its bottom 22 pixels), the item-in-hands box at QUICK.name
	            above it, and room above the bar for the touch buttons stacked over the gear and
	            the "..." button. Its cells (`quickHit`, `quickCell`, `quickIcon`) are Minecraft's
	            hotbar's, nine 20 pixel steps, so the spectator menu (Ui/SpectatorGui) and the
	            inventory's quickbar band share them; `quickKey` is the key name a cell's number
	            box shows. The attack indicator's square right of the bar (`attack`) is kept clear
	            too. `hudRaise` makes the canvas taller on top (nothing raises it now; kept for its
	            callers).
	  status    the status icons' block (Ui/StatusLayout's sizes, `status`: a full variant with the
	            knowledge bar, a lean one without), placed after the minimap column and the day
	            line and before everything else: at the bottom right on the canvas' base line (its
	            right edge the lift in, at least the margin), else right-aligned and raised over
	            whatever it hits there (the canvas, the touch buttons), else left of the touch
	            buttons in the bottom right corner, else above the canvas, right-aligned with it;
	            the full variant first, then the lean one, then the lean one smaller in eighths
	            down to half the scale but never under 8 / 7 (its 7 pixel text stays 8 screen
	            pixels tall). On a touch screen it never goes into the thumbstick's zone. The
	            saving icon, the toasts and the effect icons keep clear of it.
	  minimap  MINIMAP (Config.UiScale.Minimap, 56) GUI pixels square in the area's top right
	            corner, the coordinates line (the pixel font, COORDS_HEIGHT tall, as wide as its
	            text: `coordsWidth`, right aligned) GAP under it. Off on a touch screen, the MAP
	            button takes the corner (the only way to the world map there), never smaller than
	            a finger's TOUCH_TARGET (`mapButtonSize`); `touchSide` is the same floor for the
	            minimap's own weather button (Map/Minimap).
	  day line  the day counter (Ui/SurvivorHud: "Day 4 · Survived 2 days", a blood moon's
	            warning), as tall as the coordinates line (COORDS_HEIGHT) and as wide as its text
	            (`dayWidth`, at least the minimap's width), right aligned, GAP under the column's
	            last piece: the coordinates line, else (touch, the minimap off) the Map button,
	            else at the area's top right. Where that row doesn't fit (with a warning it is 45
	            to 50 characters, 360 to 400 GUI pixels, and an iPad's or a 1024 x 768 window's
	            area is about 320 at its Auto scale) the warning goes on a second row under the day's
	            text (`dayWrap`, its wider row's width; `dayRows` 2), so the line never goes
	            away while it carries the warning. The column's bottom moves under it, so the
	            toasts and the effect icons follow, and WAILA keeps left of it where it is wider.
	  in the way  Roblox's touch controls (the live JumpButton and ContextActionService buttons,
	            `buttons`; on a touch screen without them PlayerModule's jump button rule:
	            `jumpButton`), which never scale with the GUI scale, so they are measured, not
	            guessed in GUI pixels; the HUD's canvas and its attack square; the status icons.
	            Nothing of the corner covers them.
	  saving    while it shows: the bottom right, raised above every button in its way (by the
	            buttons' real size, not a fixed raise times the scale) and over the status icons;
	            dropped if that reaches the minimap column.
	  toasts    slot 1 starts GAP under the column (the day line, the coordinates line, the Map
	            button, or the area's top): the Now Playing toast's place, shown or not (it slides
	            in there).
	            The "World saved" toast takes slot 1 unless Now Playing shows or it already went
	            under it (`saveUnder`: SaveIndicator never moves it back up while it shows), then
	            slot 2 GAP under slot 1. A toast that cannot go there (the saving icon, a button or
	            the bottom in the way: small phones) goes beside slot 1, left of it, else it waits
	            (nil) until there is room, as Minecraft's toasts queue for a free slot. A notice
	            (`notice`: the blood moon's, Ui/SurvivorHud) goes GAP under the lowest toast
	            showing at the right edge (slot 1 when none), by the same rules.
	  effects   the icons' block (rows of 24 x 24 icons, `effectsSize`) takes the toast slot while
	            no toast shows, else goes under the lowest toast showing; when that reaches the
	            bottom, a button or the saving icon, it goes beside the toasts (left of them), else
	            beside the minimap column at the top (`effectsAside`), and as a last resort it is
	            drawn smaller (`effectsScale`, down to half the scale) before it is dropped. On a
	            touch screen it never goes into the movement thumbstick's zone (`thumbstick`:
	            PlayerModule's DynamicThumbstick, as Interaction/BlockInteraction keeps out of it):
	            the icons are buttons, and a thumb landing on one would pin its tooltip instead of
	            moving.
	  WAILA     keeps left of `wailaRight` (the map or the Map button, and anything put beside the
	            column at the top) and, when it is tall enough to reach the coordinates line
	            (`wailaLow.y`, with F3's extended lines), left of `wailaLow.right` too; with F3
	            open, right of `wailaAvoid` (`debugRight`, the F3 text's right edge, plus GAP).

	`rows` are the old Minecraft canvas' rows (the hearts and armor on the left; Minecraft's hunger
	shanks, Tough As Nails' droplets and thermometer on the right; the item name, the status row
	and the Thermometer's reading above them: 70 GUI pixels, 80 with the shanks), kept as they were
	for the Hunger spec, which pins where the food bar went. Nothing draws them any more: the status
	icons took their place.

	Every rectangle that shows is disjoint from every other, from the buttons and from the HUD
	(tested over phones, tablets, desktops and 4K, every GUI Scale choice, the minimap on and off,
	touch on and off, toasts, the saving icon and the status icons showing or not). Client
	Ui/UiScale feeds it the screen, the scale and what shows, and hands the result to Map/Minimap,
	MusicToast, SaveIndicator, EffectHud, StatusCluster and Waila.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Hunger = require(Shared.Hunger)

local HudLayout = {}

-- GUI pixels: kept free inside the area's edges, and between neighbours.
HudLayout.MARGIN = 4
HudLayout.GAP = 2
-- The minimap's side, the coordinates line's height (the pixel font with its shadow).
HudLayout.MINIMAP = Config.UiScale.Minimap
HudLayout.COORDS_HEIGHT = 10
-- The touch screen's Map button (the minimap off).
HudLayout.MAP_BUTTON_WIDTH = 32
HudLayout.MAP_BUTTON_HEIGHT = 16
-- Screen pixels a button a finger taps is at least (high, and the Map button twice as wide):
-- small phones' GUI scales (1.25 to 1.625) would make the corner's buttons 11 to 26 pixels.
HudLayout.TOUCH_TARGET = 32
-- Minecraft's toast.
HudLayout.TOAST_WIDTH = 160
HudLayout.TOAST_HEIGHT = 32
-- The saving icon: "Saving..." and the bobbing grass block.
HudLayout.SAVING_WIDTH = 80
HudLayout.SAVING_HEIGHT = 16
-- Minecraft's status effect icons: 24 x 24, a step of 25 across and 26 between the rows, and
-- the line naming a hovered one under the rows.
HudLayout.EFFECT_STEP = 25
HudLayout.EFFECT_ROW = 26
HudLayout.EFFECT_TIP = 12
-- The bottom lift on a PC: this share of the screen's height (see the header).
HudLayout.LIFT = 0.05

-- Ui/Hud's canvas (GUI pixels): the quickbar's width (230 with the touch buttons beside it) and
-- the canvas' height; the quickbar's top and the item-in-hands box's top in it (see the header).
export type Canvas = { width: number, touchWidth: number, height: number }
HudLayout.CANVAS = table.freeze({ width = 182, touchWidth = 230, height = 46 }) :: Canvas
HudLayout.QUICK = table.freeze({ bar = 24, name = 11 })
HudLayout.HUD_WIDTH = HudLayout.CANVAS.width
HudLayout.HUD_TOUCH_WIDTH = HudLayout.CANVAS.touchWidth
HudLayout.HUD_HEIGHT = HudLayout.CANVAS.height
-- The quickbar's step: nine cells 20 GUI pixels apart (Minecraft's hotbar).
HudLayout.QUICK_STEP = 20
-- The attack indicator's square beside the quickbar (Ui/Hud, `attackX`): on a touch screen right
-- of the "..." button, otherwise left of the bar (the bottom right is the status icons'); its
-- side, its top 2 under the bar's; the touch buttons' step beside the bar.
HudLayout.ATTACK_X = 188
HudLayout.ATTACK_SIZE = 18
HudLayout.TOUCH_SHIFT = 24

-- Minecraft's old canvas rows (`rows`, see the header): a row, the side rows' width, the canvas
-- without the shanks' row and the row they add (Config.Hunger on).
HudLayout.ROW = 10
HudLayout.ROW_WIDTH = 81
HudLayout.HUD_BASE_HEIGHT = 70
HudLayout.HUNGER_ROW = if Hunger.on() then HudLayout.ROW else 0

-- A rectangle in screen pixels.
export type Rect = { x: number, y: number, w: number, h: number }

-- The status icons' sizes (GUI pixels, Ui/StatusLayout.size): with the knowledge bar and without.
export type StatusSizes = { full: { w: number, h: number }, lean: { w: number, h: number } }

-- The tops of the canvas' rows (GUI pixels from its top; see the header).
export type Rows = {
	-- The canvas' height and the hotbar's top.
	height: number,
	bar: number,
	-- Left: the hearts and the armor above them.
	hearts: number,
	armor: number,
	-- Right: the hunger shanks (nil without hunger), the thirst droplets, the thermometer.
	food: number?,
	thirst: number,
	gauge: number,
	-- The held item's name in survival (centred) and in creative (lower: no hearts).
	name: number,
	nameCreative: number,
	-- Tough As Nails' status row over the name, and the Thermometer's reading over that.
	status: number,
	reading: number,
}

-- The safe area's insets from each edge, and the top bar's bottom from the screen's top.
export type Insets = { left: number, top: number, right: number, bottom: number, bar: number }

export type Input = {
	-- The screen (the camera's viewport).
	width: number,
	height: number,
	insets: Insets,
	-- The GUI scale (Ui/UiScale.base) and whether this is a touch screen.
	scale: number,
	touch: boolean,
	-- The minimap shows; its coordinates line's text width (GUI pixels).
	minimap: boolean,
	coordsWidth: number,
	-- Now Playing shows; "World saved" shows (its width, GUI pixels) and sits under Now Playing.
	music: boolean,
	save: number?,
	saveUnder: boolean,
	-- The status effect icons' block (GUI pixels: `effectsSize`), nil without effects.
	effects: { w: number, h: number }?,
	-- The saving icon shows.
	saving: boolean,
	-- The F3 text's right edge (screen pixels) while it is open.
	debugRight: number?,
	-- The day line shows (Ui/SurvivorHud), its width on one row and, with a blood moon's notice
	-- that can wrap onto a second row, its width wrapped (GUI pixels; nil: no notice).
	dayLine: boolean?,
	dayWidth: number?,
	dayWrap: number?,
	-- A notice toast shows (its width, GUI pixels; Ui/SurvivorHud's blood moon notices).
	notice: number?,
	-- GUI pixels the HUD reaches above its canvas (0 or nil: none; nothing raises it now).
	hudRaise: number?,
	-- Roblox's touch controls (screen pixels); nil: `jumpButton`'s rule on a touch screen.
	buttons: { Rect }?,
	-- The status icons' sizes (Ui/StatusCluster through UiScale.setStatus); nil: none shown.
	status: StatusSizes?,
}

export type Layout = {
	scale: number,
	-- The safe area within the margins.
	area: Rect,
	minimap: Rect?,
	coords: Rect?,
	mapButton: Rect?,
	-- Now Playing's place (also while hidden: it slides in there); nil when it shows and must
	-- wait for room.
	music: Rect?,
	-- "World saved" while it shows (nil while it waits for room).
	save: Rect?,
	-- The day line (nil: none, or no room) and its rows (1; 2 with its notice wrapped under its
	-- text), and a notice toast while it shows (nil: none, or no room yet).
	day: Rect?,
	dayRows: number,
	notice: Rect?,
	-- The status effect icons' block, the scale it is drawn at, and whether it went beside the
	-- minimap column or the toasts.
	effects: Rect?,
	effectsScale: number,
	effectsAside: boolean,
	saving: Rect?,
	-- The status icons (nil: none, or no room), the scale they are drawn at and their variant
	-- ("full" or "lean"; nil with no icons).
	status: Rect?,
	statusScale: number,
	statusVariant: string?,
	-- What the corner keeps clear of: the touch controls, the HUD's canvas and its attack square.
	buttons: { Rect },
	hud: Rect,
	attack: Rect,
	-- WAILA keeps left of `wailaRight`, left of `wailaLow.right` when it reaches down to
	-- `wailaLow.y`, and right of `wailaAvoid` (screen pixels).
	wailaRight: number,
	wailaLow: { y: number, right: number }?,
	wailaAvoid: number?,
}

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end

-- Do `a` and `b` overlap (touching edges do not)?
function HudLayout.overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- Is `r` inside `outer`?
function HudLayout.inside(r: Rect, outer: Rect): boolean
	return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w and r.y + r.h <= outer.y + outer.h
end

-- The safe area below the top bar (no margins): what every placed rectangle must stay inside.
function HudLayout.safeArea(width: number, height: number, insets: Insets): Rect
	local top = math.max(insets.top, insets.bar)
	return rect(insets.left, top, width - insets.left - insets.right, height - top - insets.bottom)
end

--[[
	Roblox's jump button on a touch screen (PlayerModule's TouchJump in its TouchGui, which keeps
	below the top bar and inside the safe area): 70 pixels at (right - 95, bottom - 90) when the
	smaller side of that area is at most 500 pixels, else 120 at (right - 170, bottom - 210).
]]
function HudLayout.jumpButton(width: number, height: number, insets: Insets): Rect
	local right, bottom = width - insets.right, height - insets.bottom
	local small = math.min(right - insets.left, bottom - math.max(insets.top, insets.bar)) <= 500
	if small then
		return rect(right - 95, bottom - 90, 70, 70)
	end
	return rect(right - 170, bottom - 210, 120, 120)
end

--[[
	Where a touch screen's movement thumbstick starts (PlayerModule's DynamicThumbstick, the same
	rule as Interaction/BlockInteraction's): in landscape the left 40% below the top third, in
	portrait the bottom 40%.
]]
function HudLayout.thumbstick(width: number, height: number): Rect
	if width >= height then
		return rect(0, height / 3, width * 0.4, height - height / 3)
	end
	return rect(0, height * 0.6, width, height * 0.4)
end

-- The Map button's size (screen pixels) at `scale`: its GUI size, at least TOUCH_TARGET high.
function HudLayout.mapButtonSize(scale: number): (number, number)
	local w = math.max(HudLayout.MAP_BUTTON_WIDTH * scale, 2 * HudLayout.TOUCH_TARGET)
	local h = math.max(HudLayout.MAP_BUTTON_HEIGHT * scale, HudLayout.TOUCH_TARGET)
	return w, h
end

-- GUI pixels a button `side` GUI pixels square takes at `scale` so a finger finds it (at least
-- TOUCH_TARGET screen pixels).
function HudLayout.touchSide(side: number, scale: number): number
	return math.max(side, math.ceil(HudLayout.TOUCH_TARGET / scale))
end

--[[
	The canvas' rows with the hunger shanks or without (see the header): Minecraft's hotbar 22
	high at the bottom, the hearts 17 above its top, the item name 37 above it (23 without hearts),
	a row higher and the canvas a row taller with the shanks.
]]
function HudLayout.rows(hunger: boolean): Rows
	local row = HudLayout.ROW
	local extra = if hunger then row else 0
	local height = HudLayout.HUD_BASE_HEIGHT + extra
	local bar = height - 22
	local hearts = bar - 17
	local thirst = hearts - extra
	local name = bar - 37 - extra
	return {
		height = height,
		bar = bar,
		hearts = hearts,
		armor = hearts - row,
		food = if hunger then hearts else nil,
		thirst = thirst,
		gauge = thirst - row,
		name = name,
		nameCreative = bar - 23,
		status = name - row,
		reading = name - 2 * row,
	}
end

-- Screen pixels the HUD's bottom sits above the safe area's (see the header): 0 on touch screens.
function HudLayout.lift(height: number, touch: boolean): number
	if touch then
		return 0
	end
	return math.floor(HudLayout.LIFT * height)
end

--[[
	Screen pixels above the safe area's bottom for what Minecraft draws `offset` GUI pixels above
	the screen's bottom, over its hotbar (Ui/Chat's lines and overlay message), at `scale` on a
	screen `height` tall: lifted with the HUD's canvas (see the header).
]]
function HudLayout.lifted(offset: number, scale: number, height: number, touch: boolean): number
	return offset * scale + HudLayout.lift(height, touch)
end

--[[
	Ui/Hud's canvas (`canvas`, default CANVAS) at `scale` (at most: the HUD shrinks to fit narrower
	screens), `raise` GUI pixels taller on top, centred in the safe area, its bottom one pixel and
	the lift above the safe area's.
]]
function HudLayout.hud(
	width: number,
	height: number,
	insets: Insets,
	scale: number,
	touch: boolean,
	raise: number?,
	canvas: Canvas?
): Rect
	local shape = canvas or HudLayout.CANVAS
	local w = (if touch then shape.touchWidth else shape.width) * scale
	local h = (shape.height + math.max(raise or 0, 0)) * scale
	local safeWidth = width - insets.left - insets.right
	local bottom = height - insets.bottom - 1 - HudLayout.lift(height, touch)
	return rect(insets.left + (safeWidth - w) / 2, bottom - h, w, h)
end

--[[
	The attack indicator's square's x (GUI pixels from the quickbar's left; its top is 2 under the
	bar's): right of the "..." button on a touch screen (Minecraft's right of the hotbar), else left
	of the bar, Minecraft's left-handed place, as the status icons take the right.
]]
function HudLayout.attackX(touch: boolean): number
	if touch then
		return HudLayout.ATTACK_X + HudLayout.TOUCH_SHIFT
	end
	return -(HudLayout.ATTACK_SIZE + 6)
end

-- The attack indicator's square (screen pixels) of the canvas `hud` (HudLayout.hud's) at `scale`.
function HudLayout.attack(hud: Rect, scale: number, touch: boolean, canvas: Canvas?): Rect
	local shape = canvas or HudLayout.CANVAS
	-- (The quickbar is centred in the canvas; the canvas' bottom is the bar's.)
	local barLeft = hud.x + (hud.w - shape.width * scale) / 2
	local top = hud.y + hud.h - (shape.height - HudLayout.QUICK.bar - 2) * scale
	local side = HudLayout.ATTACK_SIZE * scale
	return rect(barLeft + HudLayout.attackX(touch) * scale, top, side, side)
end

-- Quickbar cell `i`'s hit area (GUI pixels) with the bar's top at `bar`: its 20 pixel step.
function HudLayout.quickHit(i: number, bar: number): Rect
	return rect(1 + HudLayout.QUICK_STEP * (i - 1), bar + 1, 20, 20)
end

-- Quickbar cell `i`'s 18 x 18 face (GUI pixels) with the bar's top at `bar`.
function HudLayout.quickCell(i: number, bar: number): Rect
	return rect(2 + HudLayout.QUICK_STEP * (i - 1), bar + 2, 18, 18)
end

-- Quickbar cell `i`'s 16 x 16 item (GUI pixels) with the bar's top at `bar`.
function HudLayout.quickIcon(i: number, bar: number): Rect
	return rect(3 + HudLayout.QUICK_STEP * (i - 1), bar + 3, 16, 16)
end

--[[
	What a quickbar cell's number box shows for a key named `text` (Settings/Keybinds.name): the
	name itself when it is one or two characters ("1", "F1"), else nothing (the box is six GUI
	pixels wide: "Left Shift" or "Not Bound" would not fit).
]]
function HudLayout.quickKey(text: string): string
	local length = utf8.len(text)
	if length == nil or length < 1 or length > 2 then
		return ""
	end
	return text
end

--[[
	The status effect icons' block for `columns` icons in the longest row and `rows` rows (0 for
	none): Minecraft's 24 pixel squares 25 apart, rows 26 apart, and the line naming a hovered one.
]]
function HudLayout.effectsSize(columns: number, rows: number): { w: number, h: number }?
	if columns <= 0 or rows <= 0 then
		return nil
	end
	return {
		w = (columns - 1) * HudLayout.EFFECT_STEP + 24,
		h = (rows - 1) * HudLayout.EFFECT_ROW + 24 + HudLayout.EFFECT_TIP,
	}
end

-- `r` with its corner on whole pixels (sizes stay exact: GUI pixels x the scale).
local function snap(r: Rect): Rect
	r.x = math.floor(r.x + 0.5)
	r.y = math.floor(r.y + 0.5)
	return r
end

-- The first of `placed` that `r` overlaps.
local function hit(r: Rect, placed: { Rect }): Rect?
	for _, other in placed do
		if HudLayout.overlaps(r, other) then
			return other
		end
	end
	return nil
end

-- What is being placed into: the safe area, the margins' area, what is placed, the gap.
type Space = { safe: Rect, area: Rect, placed: { Rect }, gap: number }

--[[
	A `w` x `h` rectangle at height `y`, at the area's right edge or slid left past everything
	placed in its way; nil when it would leave the area.
]]
local function slideLeft(space: Space, y: number, w: number, h: number): Rect?
	local area = space.area
	local x = area.x + area.w - w
	for _ = 1, #space.placed + 1 do
		local r = snap(rect(x, y, w, h))
		local other = hit(r, space.placed)
		if other == nil then
			return if HudLayout.inside(r, space.safe) then r else nil
		end
		x = other.x - space.gap - w
		if x < area.x then
			return nil
		end
	end
	return nil
end

-- The first place for a `w` x `h` rectangle: at the right edge at `y`, else slid left at each of
-- `beside` (heights); the rectangle and whether it is beside something.
local function find(space: Space, y: number, beside: { number }, w: number, h: number): (Rect?, boolean)
	local area = space.area
	local first = snap(rect(area.x + area.w - w, y, w, h))
	if HudLayout.inside(first, space.safe) and hit(first, space.placed) == nil then
		return first, false
	end
	for _, height in beside do
		local r = slideLeft(space, height, w, h)
		if r then
			return r, true
		end
	end
	return nil, false
end

-- The scales the effect icons try, the GUI scale first, then smaller (eighths, at least half).
local function effectScales(scale: number): { number }
	local list = { scale }
	for _, share in { 0.75, 0.5 } do
		local smaller = math.max(math.floor(scale * share * 8) / 8, 0.5)
		if smaller < list[#list] then
			table.insert(list, smaller)
		end
	end
	return list
end

-- The status icons' smallest scale: their 7 pixel text stays 8 screen pixels tall.
HudLayout.STATUS_MIN_SCALE = 8 / 7

--[[
	Where the status icons go (see the header): their rectangle, scale and variant, or nil when no
	try finds room. `hud` is the canvas, `buttons` Roblox's touch controls.
]]
local function placeStatus(
	input: Input,
	space: Space,
	hud: Rect,
	buttons: { Rect },
	sizes: StatusSizes
): (Rect?, number, string?)
	local s = input.scale
	local safe, gap = space.safe, space.gap
	local edge = safe.x + safe.w - math.max(HudLayout.lift(input.height, input.touch), HudLayout.MARGIN * s)
	local base = hud.y + hud.h
	local kept = space.placed
	if input.touch then
		-- (Never in the thumbstick's zone: see the header.)
		kept = table.clone(kept)
		table.insert(kept, HudLayout.thumbstick(input.width, input.height))
	end
	-- (The leftmost touch button in the bottom right quarter.)
	local leftButton: number? = nil
	for _, button in buttons do
		if button.x + button.w > input.width / 2 and button.y + button.h > input.height / 2 then
			leftButton = math.min(leftButton or math.huge, button.x)
		end
	end
	local function fits(r: Rect): boolean
		return HudLayout.inside(r, safe) and hit(r, kept) == nil
	end
	-- Right-aligned on the base line, raised over whatever it hits there.
	local function raised(w: number, h: number): Rect?
		local r = snap(rect(edge - w, base - h, w, h))
		for _ = 1, #kept + 1 do
			local other = hit(r, kept)
			if other == nil then
				return if HudLayout.inside(r, safe) then r else nil
			end
			r = snap(rect(r.x, other.y - gap - h, w, h))
			if r.y < safe.y then
				return nil
			end
		end
		return nil
	end
	-- Left of the touch buttons in the bottom right corner, on the base line.
	local function besideButtons(w: number, h: number): Rect?
		if leftButton == nil then
			return nil
		end
		local r = snap(rect(leftButton - gap - w, base - h, w, h))
		return if fits(r) then r else nil
	end
	-- Above the canvas, right-aligned with it, slid left past whatever is in the way there.
	local function aboveCanvas(w: number, h: number): Rect?
		local y = hud.y - gap - h
		local x = hud.x + hud.w - w
		for _ = 1, #kept + 1 do
			local r = snap(rect(x, y, w, h))
			local other = hit(r, kept)
			if other == nil then
				return if HudLayout.inside(r, safe) then r else nil
			end
			x = other.x - gap - w
			if x < safe.x then
				return nil
			end
		end
		return nil
	end
	local function try(w: number, h: number): Rect?
		local first = snap(rect(edge - w, base - h, w, h))
		if fits(first) then
			return first
		end
		if input.touch then
			-- (Roblox's jump button owns the bottom right of a touch screen: rather than climb the
			-- right edge over it, where the saving icon, the toasts and the effect icons come down,
			-- the icons sit by the buttons or on the quickbar's end.)
			return besideButtons(w, h) or aboveCanvas(w, h) or raised(w, h)
		end
		return raised(w, h) or besideButtons(w, h) or aboveCanvas(w, h)
	end
	local full, lean = sizes.full, sizes.lean
	local whole = try(full.w * s, full.h * s)
	if whole then
		return whole, s, "full"
	end
	-- (The lean variant at the scale, then smaller.)
	local floor = math.max(s / 2, HudLayout.STATUS_MIN_SCALE)
	local es = s
	while es == s or es >= floor do
		local r = try(lean.w * es, lean.h * es)
		if r then
			return r, es, "lean"
		end
		es -= 1 / 8
	end
	return nil, s, nil
end

function HudLayout.compute(input: Input): Layout
	local s = input.scale
	local margin, gap = HudLayout.MARGIN * s, HudLayout.GAP * s
	local insets = input.insets
	local safe = HudLayout.safeArea(input.width, input.height, insets)
	local area = rect(safe.x + margin, safe.y + margin, safe.w - 2 * margin, safe.h - 2 * margin)
	local right = area.x + area.w
	local bottom = area.y + area.h

	local buttons: { Rect } = input.buttons
		or (if input.touch then { HudLayout.jumpButton(input.width, input.height, insets) } else {})
	local hud = HudLayout.hud(input.width, input.height, insets, s, input.touch, input.hudRaise, HudLayout.CANVAS)
	local attack = HudLayout.attack(hud, s, input.touch, HudLayout.CANVAS)
	-- Everything placed so far that later pieces keep clear of (the buttons and the HUD first).
	local placed: { Rect } = table.clone(buttons)
	table.insert(placed, hud)
	table.insert(placed, attack)
	local space: Space = { safe = safe, area = area, placed = placed, gap = gap }

	local layout: Layout = {
		scale = s,
		area = area,
		minimap = nil,
		coords = nil,
		mapButton = nil,
		music = nil,
		save = nil,
		day = nil,
		dayRows = 1,
		notice = nil,
		effects = nil,
		effectsScale = s,
		effectsAside = false,
		saving = nil,
		status = nil,
		statusScale = s,
		statusVariant = nil,
		buttons = buttons,
		hud = hud,
		attack = attack,
		wailaRight = right,
		wailaLow = nil,
		wailaAvoid = nil,
	}

	--[[ The column: the minimap and its coordinates line, or the Map button ]]

	-- (Where the column ends.)
	local columnBottom = area.y - gap
	local top: Rect? = nil
	if input.minimap then
		local side = HudLayout.MINIMAP * s
		local map = snap(rect(right - side, area.y, side, side))
		local width = math.max(input.coordsWidth, HudLayout.MINIMAP) * s
		local coords = snap(rect(right - width, map.y + map.h + gap, width, HudLayout.COORDS_HEIGHT * s))
		layout.minimap, layout.coords = map, coords
		table.insert(placed, map)
		table.insert(placed, coords)
		top = map
		columnBottom = coords.y + coords.h
	elseif input.touch then
		local w, h = HudLayout.mapButtonSize(s)
		local button = snap(rect(right - w, area.y, w, h))
		layout.mapButton = button
		table.insert(placed, button)
		top = button
		columnBottom = button.y + button.h
	end
	-- (The day line under the column, or in the corner, on one row or wrapped onto two; the column
	-- ends under it.)
	if input.dayLine then
		local y = if top then columnBottom + gap else area.y
		local function dayRect(w: number, rows: number): Rect?
			local width = math.max(w, HudLayout.MINIMAP) * s
			local r = snap(rect(right - width, y, width, HudLayout.COORDS_HEIGHT * rows * s))
			return if HudLayout.inside(r, safe) and hit(r, placed) == nil then r else nil
		end
		local day, rows = dayRect(input.dayWidth or 0, 1), 1
		local wrap = input.dayWrap
		if day == nil and wrap then
			day, rows = dayRect(wrap, 2), 2
		end
		if day then
			layout.day, layout.dayRows = day, rows
			table.insert(placed, day)
			top = top or day
			columnBottom = day.y + day.h
		end
	end
	local slotTop = columnBottom + gap

	-- The saving icon's place with what is placed so far: bottom right, raised above the buttons,
	-- the HUD and the status icons in its way; nil when that reaches the column.
	local function savingPlace(): Rect?
		local w, h = HudLayout.SAVING_WIDTH * s, HudLayout.SAVING_HEIGHT * s
		local icon = snap(rect(right - w, bottom - h, w, h))
		for _ = 1, #placed + 1 do
			local under = hit(icon, placed)
			if under == nil or under.y >= icon.y + icon.h or under.y < slotTop then
				break
			end
			icon = snap(rect(icon.x, under.y - gap - h, w, h))
		end
		return if HudLayout.inside(icon, safe) and hit(icon, placed) == nil then icon else nil
	end

	--[[ The status icons: bottom right on the canvas' base line, or the next best place ]]

	local status = input.status
	if status then
		-- (On a touch screen the icons keep out of the saving icon's place over the jump button
		-- whether it shows or not, so they never move when the game saves.)
		local reserved = if input.touch then savingPlace() else nil
		local statusSpace = space
		if reserved then
			local kept = table.clone(placed)
			table.insert(kept, reserved)
			statusSpace = { safe = safe, area = area, placed = kept, gap = gap }
		end
		local placedStatus, statusScale, variant = placeStatus(input, statusSpace, hud, buttons, status)
		if placedStatus then
			layout.status, layout.statusScale, layout.statusVariant = placedStatus, statusScale, variant
			table.insert(placed, placedStatus)
		end
	end

	--[[ The saving icon: bottom right, above the buttons in its way ]]

	if input.saving then
		local icon = savingPlace()
		if icon then
			layout.saving = icon
			table.insert(placed, icon)
		end
	end

	--[[ The toasts ]]

	local toastH = HudLayout.TOAST_HEIGHT * s
	local musicW = HudLayout.TOAST_WIDTH * s
	local slot1 = snap(rect(right - musicW, slotTop, musicW, toastH))
	-- The lowest toast showing at the right edge (the effect icons go under it).
	local toastBottom: number? = nil
	-- (Toasts that find no room wait, as Minecraft's queue does: nil until the room frees.)
	local besideToasts = { slotTop }
	if input.music then
		local music, moved = find(space, slotTop, besideToasts, musicW, toastH)
		layout.music = music
		if music then
			table.insert(placed, music)
			if not moved then
				toastBottom = music.y + music.h
			end
		end
	else
		layout.music = slot1
	end
	local saveWidth = input.save
	if saveWidth then
		local w = math.max(saveWidth, HudLayout.TOAST_WIDTH) * s
		local y = if input.music or input.saveUnder then slot1.y + slot1.h + gap else slotTop
		local save, moved = find(space, y, besideToasts, w, toastH)
		layout.save = save
		if save then
			table.insert(placed, save)
			if not moved then
				toastBottom = math.max(toastBottom or 0, save.y + save.h)
			end
		end
	end
	local noticeWidth = input.notice
	if noticeWidth then
		local w = math.max(noticeWidth, HudLayout.TOAST_WIDTH) * s
		local y = if toastBottom then toastBottom + gap else slotTop
		local notice, moved = find(space, y, besideToasts, w, toastH)
		layout.notice = notice
		if notice then
			table.insert(placed, notice)
			if not moved then
				toastBottom = math.max(toastBottom or 0, notice.y + notice.h)
			end
		end
	end

	--[[ The status effect icons ]]

	local effects = input.effects
	if effects and effects.w > 0 and effects.h > 0 then
		local y = if toastBottom then toastBottom + gap else slotTop
		-- (On touch, never in the thumbstick's zone: see the header.)
		local effectSpace = space
		if input.touch then
			local kept = table.clone(placed)
			table.insert(kept, HudLayout.thumbstick(input.width, input.height))
			effectSpace = { safe = safe, area = area, placed = kept, gap = gap }
		end
		for _, es in effectScales(s) do
			local block, moved = find(effectSpace, y, { slotTop, area.y }, effects.w * es, effects.h * es)
			if block then
				layout.effects, layout.effectsScale, layout.effectsAside = block, es, moved
				table.insert(placed, block)
				break
			end
		end
	end

	--[[ WAILA ]]

	local wailaRight = if top then top.x - gap else right
	-- (Pieces put beside the column at the top are in its way too.)
	for _, piece in { layout.music, layout.save, layout.notice, layout.effects } do
		if piece and piece.y < slotTop and (piece ~= layout.music or input.music) then
			wailaRight = math.min(wailaRight, piece.x - gap)
		end
	end
	layout.wailaRight = math.floor(wailaRight)
	-- (The column's lower pieces, the coordinates and the day line, may be wider than its top.)
	local low: { y: number, right: number }? = nil
	for _, piece in { layout.coords, layout.day } do
		if piece and piece ~= top then
			local edge = math.floor(math.min(wailaRight, piece.x - gap))
			low = if low then { y = low.y, right = math.min(low.right, edge) } else { y = piece.y, right = edge }
		end
	end
	layout.wailaLow = low
	local debugRight = input.debugRight
	if debugRight then
		layout.wailaAvoid = math.ceil(debugRight + gap)
	end
	return layout
end

return HudLayout
