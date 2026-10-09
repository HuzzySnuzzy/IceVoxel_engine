--!strict
--[[
	Where the HUD's shared corner goes (pure: numbers in, rectangles out, so the tests place every
	screen and every GUI Scale choice): the top right corner holds the minimap with its
	coordinates line (or the touch "Map" button while the minimap is off), the toasts under it
	(Minecraft's ToastComponent: the Now Playing toast in the first slot, the "World saved" toast
	in it or under it), the status effect icons (Minecraft's Gui.renderEffects: the top right) and
	the saving icon at the bottom right; WAILA keeps out of them, and right of the F3 text.

	Everything is in screen pixels: (0, 0) the screen's top left, `width` x `height` the camera's
	viewport. Sizes are GUI pixels (below) times the GUI scale, so the corner grows and shrinks
	with the GUI Scale setting like the rest of the HUD (the minimap ignored it before: 192 pixels
	whatever the scale, and everything under it was pinned to those pixels). The rules:

	  area      the device's safe area (notches: `insets`), below Roblox's top bar (`insets.bar`,
	            from the screen's top), MARGIN GUI pixels inside it; everything placed stays in it
	            or is dropped (nil) when it cannot fit.
	  minimap   MINIMAP (Config.UiScale.Minimap, 56) GUI pixels square in the area's top right
	            corner, the coordinates line (the pixel font, COORDS_HEIGHT tall, as wide as its
	            text: `coordsWidth`, right aligned) GAP under it. Off on a touch screen, the MAP
	            button takes the corner (the only way to the world map there), never smaller than
	            a finger's TOUCH_TARGET (`mapButtonSize`); `touchSide` is the same floor for the
	            minimap's own weather button (Map/Minimap).
	  in the way  Roblox's touch controls (the live JumpButton and ContextActionService buttons,
	            `buttons`; on a touch screen without them PlayerModule's jump button rule:
	            `jumpButton`), which never scale with the GUI scale, so they are measured, not
	            guessed in GUI pixels; and the HUD's canvas (Ui/Hud: 182 x 70 GUI pixels, 230 wide
	            with the touch buttons, at the bottom centre; `hudRaise` taller while its name and
	            status row sit higher over the mana stars). Nothing of the corner covers them.
	  saving    while it shows: the bottom right, raised above every button in its way (by the
	            buttons' real size, not a fixed raise times the scale); dropped if that reaches the
	            minimap column.
	  toasts    slot 1 starts GAP under the column (the coordinates line, the Map button, or the
	            area's top): the Now Playing toast's place, shown or not (it slides in there).
	            The "World saved" toast takes slot 1 unless Now Playing shows or it already went
	            under it (`saveUnder`: SaveIndicator never moves it back up while it shows), then
	            slot 2 GAP under slot 1. A toast that cannot go there (the saving icon, a button or
	            the bottom in the way: small phones) goes beside slot 1, left of it, else it waits
	            (nil) until there is room, as Minecraft's toasts queue for a free slot.
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

	Every rectangle that shows is disjoint from every other, from the buttons and from the HUD
	(tested over phones, tablets, desktops and 4K, every GUI Scale choice, the minimap on and off,
	touch on and off, toasts and the saving icon showing or not). Client Ui/UiScale feeds it the
	screen, the scale and what shows, and hands the result to Map/Minimap, MusicToast,
	SaveIndicator, EffectHud and Waila.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

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
-- Ui/Hud's canvas: the hotbar, hearts, armour and item name (wider with the touch buttons beside
-- the hotbar), one pixel above the safe area's bottom; `hudRaise` more on top while the name and
-- the status row are moved up over Terraria's mana stars.
HudLayout.HUD_WIDTH = 182
HudLayout.HUD_TOUCH_WIDTH = 230
HudLayout.HUD_HEIGHT = 70

-- A rectangle in screen pixels.
export type Rect = { x: number, y: number, w: number, h: number }

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
	-- GUI pixels the HUD's held item name and status row reach above its canvas (Ui/Hud: they
	-- move up over Terraria's mana stars, Ui/ManaStars.layout; 0 or nil without).
	hudRaise: number?,
	-- Roblox's touch controls (screen pixels); nil: `jumpButton`'s rule on a touch screen.
	buttons: { Rect }?,
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
	-- The status effect icons' block, the scale it is drawn at, and whether it went beside the
	-- minimap column or the toasts.
	effects: Rect?,
	effectsScale: number,
	effectsAside: boolean,
	saving: Rect?,
	-- What the corner keeps clear of: the touch controls, and the HUD's canvas.
	buttons: { Rect },
	hud: Rect,
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

-- Ui/Hud's canvas at `scale` (at most: the HUD shrinks to fit narrower screens), `raise` GUI
-- pixels taller on top (the text moved up over the mana stars).
function HudLayout.hud(
	width: number,
	height: number,
	insets: Insets,
	scale: number,
	touch: boolean,
	raise: number?
): Rect
	local w = (if touch then HudLayout.HUD_TOUCH_WIDTH else HudLayout.HUD_WIDTH) * scale
	local h = (HudLayout.HUD_HEIGHT + math.max(raise or 0, 0)) * scale
	local safeWidth = width - insets.left - insets.right
	return rect(insets.left + (safeWidth - w) / 2, height - insets.bottom - 1 - h, w, h)
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
	local hud = HudLayout.hud(input.width, input.height, insets, s, input.touch, input.hudRaise)
	-- Everything placed so far that later pieces keep clear of (the buttons and the HUD first).
	local placed: { Rect } = table.clone(buttons)
	table.insert(placed, hud)
	local space: Space = { safe = safe, area = area, placed = placed, gap = gap }

	local layout: Layout = {
		scale = s,
		area = area,
		minimap = nil,
		coords = nil,
		mapButton = nil,
		music = nil,
		save = nil,
		effects = nil,
		effectsScale = s,
		effectsAside = false,
		saving = nil,
		buttons = buttons,
		hud = hud,
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
	local slotTop = columnBottom + gap

	--[[ The saving icon: bottom right, above the buttons in its way ]]

	if input.saving then
		local w, h = HudLayout.SAVING_WIDTH * s, HudLayout.SAVING_HEIGHT * s
		local icon = snap(rect(right - w, bottom - h, w, h))
		-- (Raised above the buttons and the HUD in its way; reaching the column, it is dropped.)
		for _ = 1, #placed + 1 do
			local under = hit(icon, placed)
			if under == nil or under.y >= icon.y + icon.h or under.y < slotTop then
				break
			end
			icon = snap(rect(icon.x, under.y - gap - h, w, h))
		end
		if HudLayout.inside(icon, safe) and hit(icon, placed) == nil then
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
	for _, piece in { layout.music, layout.save, layout.effects } do
		if piece and piece.y < slotTop and (piece ~= layout.music or input.music) then
			wailaRight = math.min(wailaRight, piece.x - gap)
		end
	end
	layout.wailaRight = math.floor(wailaRight)
	local coords = layout.coords
	if coords then
		layout.wailaLow = { y = coords.y, right = math.floor(math.min(wailaRight, coords.x - gap)) }
	end
	local debugRight = input.debugRight
	if debugRight then
		layout.wailaAvoid = math.ceil(debugRight + gap)
	end
	return layout
end

return HudLayout
