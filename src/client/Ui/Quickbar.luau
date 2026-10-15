--!strict
--[[
	The HUD's quickbar in the survival look (Ui/Hud builds it into its canvas; Ui/SpectatorGui
	draws the spectator menu with `drawBar` and `drawSelection`): Minecraft's hotbar footprint and
	cell math (182 x 22, nine cells 20 GUI pixels apart, the items at 3 + 20(i - 1): Ui/HudLayout's
	quickHit, quickCell and quickIcon), drawn as a survival game's quickbar.

	  cells      nine separate 18 x 18 cells (Style.Dayz.quickCell: QuickCell grey at 0.47), 2
	             apart, each with its face over it. This module is the only painter of the HUD's
	             faces (Style.Dayz.paintFace): the selected slot's face olive (Selected) under its
	             icon, an occupied slot's filled (white at 0.04), an empty one's empty.
	  selection  the selected slot also gets a white outline (`drawSelection`: a 24 x 24
	             transparent frame with the outline round the 18 x 18 cell at (3, 3), no fill, so
	             the spectator menu's heads and icons under it stay visible).
	  items      Ui/ItemIcon in the survival look (tinted pictures, the count box, the condition,
	             sips or energy bar), following the HUD's scale (`scaled`). Each icon lives inside
	             its cell, at HudLayout.quickIcon (one pixel into the 18 x 18 cell) and z ICON_Z:
	             over the cell's face (z 1) and under its number box (z 3). The ScreenGuis order
	             their children by sibling (UiScale.screenGui), so an icon made beside the bar
	             instead, at any z, would draw over every part of the bar, the number boxes too.
	  numbers    each cell's key (Settings/Keybinds "hotbar1".."hotbar9", one or two characters:
	             HudLayout.quickKey; read again when the bindings change) in a number box
	             (Style.Dayz.paintNumber at Theme.quickNumber): boxed in the top right corner over
	             an item, faint in the middle of an empty cell. Hidden on touch screens (there are
	             no keys) and while the tiny text would be under 8 screen pixels (6 x scale < 8).
	  layers     from the bottom: each cell (its base, face, icon and number box, in that order),
	             the HUD's Slot buttons (Ui/Hud, z 4: transparent), the selection (z 6), the
	             hover outlines (z 7). tests/spec/Quickbar builds the bar on Roblox instances and
	             checks this order.
	  hover      the creative screen's hovered slot (`setHover`): a white outline over the cell.
	  fade       only with Config.Ui.QuickbarFadeAfter above 0 (0 by default: it never fades, as a
	             survival game's quickbar doesn't): after that many seconds without activity (a new
	             selection, a stack changing, the mode changing, `wake`: the wheel or a number key)
	             the cells, numbers, selection and items fade to Config.Ui.QuickbarFadeTo over
	             QuickbarFadeTime, and come back at once on activity; never in "creative" (the
	             creative screen's row) or while `active` (the attack indicator shows). Writes
	             happen each frame only while the fade moves.

	`render` reads the nine stacks from the window it is given and writes only what changed: no
	Instance and no table is made per frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local HudLayout = require(script.Parent.HudLayout)
local ItemIcon = require(script.Parent.ItemIcon)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

export type Mode = "play" | "creative" | "hidden"

export type Quickbar = {
	-- The 182 x 22 bar (transparent; the HUD's coverage) and its parts.
	bar: Frame,
	cells: { Style.QuickCell },
	icons: { ItemIcon.ItemIcon },
	hovers: { Frame },
	selection: Frame,
	render: (
		self: Quickbar,
		now: number,
		mode: Mode,
		window: Types.Window?,
		selected: number,
		active: boolean
	) -> (),
	wake: (self: Quickbar, now: number) -> (),
	setHover: (self: Quickbar, slot: number?) -> (),
}

type Self = Quickbar & {
	top: number,
	scaled: Style.Scaled,
	-- What each icon shows (to notice changes without building anything).
	items: { number | false },
	counts: { number },
	damages: { number },
	datas: { Items.Data | false },
	-- The key names, whether they are stale, what is shown and the fade.
	keys: { string },
	keysStale: boolean,
	numbersShown: boolean,
	shownSelected: number,
	shownMode: Mode,
	activeAt: number,
	fade: number,
}

local Quickbar = {}
Quickbar.__index = Quickbar

local SLOTS = Types.HOTBAR_SIZE
-- The tiny role's text must come out at least this many screen pixels tall to show.
local NUMBER_MIN_PX = 8
-- An icon's ZIndex inside its cell: over the face (Style.Dayz.quickCell's z 1), under the number
-- box (its z 3).
local ICON_Z = 2

-- Every Quickbar built (their key names go stale when the bindings change).
local built: { Self } = {}
local keybindsHooked = false

-- The bar and its nine cells at (x, y) of `parent` (see the header).
local function newBar(parent: Instance, x: number, y: number, scaled: Style.Scaled?): (Frame, { Style.QuickCell })
	local bar = Instance.new("Frame")
	bar.Name = "Quickbar"
	bar.BackgroundTransparency = 1
	bar.BorderSizePixel = 0
	bar.Position = UDim2.fromOffset(x, y)
	bar.Size = UDim2.fromOffset(HudLayout.CANVAS.width, 22)
	bar.ZIndex = 2
	bar.Parent = parent
	local cells: { Style.QuickCell } = {}
	for i = 1, SLOTS do
		local r = HudLayout.quickCell(i, 0)
		cells[i] = Style.Dayz.quickCell(bar, r.x, r.y, 2, scaled)
	end
	return bar, cells
end

--[[
	The quickbar's look at (x, y) of `parent`: the 182 x 22 transparent bar holding the nine cells
	(SpectatorGui's contract: its icons go at x + 1 + 20(i - 1) + 2, y + 3).
]]
function Quickbar.drawBar(parent: Instance, x: number, y: number, scaled: Style.Scaled?): Frame
	local bar = newBar(parent, x, y, scaled)
	return bar
end

--[[
	The selection: 24 x 24, transparent, a white outline round the 18 x 18 cell at (3, 3) and no
	fill (placed by the caller at (-1 + 20(i - 1), bar - 1)).
]]
function Quickbar.drawSelection(parent: Instance, scaled: Style.Scaled?): Frame
	local selection = Instance.new("Frame")
	selection.Name = "Selection"
	selection.BackgroundTransparency = 1
	selection.BorderSizePixel = 0
	selection.Size = UDim2.fromOffset(24, 24)
	selection.ZIndex = 6
	selection.Parent = parent
	local ring = Instance.new("Frame")
	ring.Name = "Outline"
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.Position = UDim2.fromOffset(3, 3)
	ring.Size = UDim2.fromOffset(18, 18)
	ring.ZIndex = 1
	ring.Parent = selection
	Style.Dayz.outline(ring, nil, nil, scaled)
	return selection
end

local function readKeys(self: Self)
	for i = 1, SLOTS do
		self.keys[i] = HudLayout.quickKey(Keybinds.name(`hotbar{i}`))
	end
	self.keysStale = false
end

--[[
	The quickbar in `hotbar` (Ui/Hud's canvas part), its bar's top at `bar` (GUI pixels), its
	strokes, icons and labels following `scaled` (the HUD's scale).
]]
function Quickbar.build(hotbar: Frame, bar: number, scaled: Style.Scaled): Quickbar
	local frame, cells = newBar(hotbar, 0, bar, scaled)
	local icons: { ItemIcon.ItemIcon } = {}
	local hovers: { Frame } = {}
	for i = 1, SLOTS do
		-- (The icon inside its cell: see the header's `items` and `layers`.)
		local r, c = HudLayout.quickIcon(i, bar), HudLayout.quickCell(i, bar)
		icons[i] = ItemIcon.new(cells[i].base, r.x - c.x, r.y - c.y, ICON_Z, "dayz", scaled)
		local hover = Instance.new("Frame")
		hover.Name = `Hover{i}`
		hover.BackgroundTransparency = 1
		hover.BorderSizePixel = 0
		hover.Position = UDim2.fromOffset(c.x, c.y)
		hover.Size = UDim2.fromOffset(c.w, c.h)
		hover.ZIndex = 7
		hover.Parent = hotbar
		Style.Dayz.outline(hover, nil, nil, scaled)
		Style.Dayz.setLit(hover, false)
		hovers[i] = hover
	end
	local selection = Quickbar.drawSelection(hotbar, scaled)
	local self: Self = setmetatable({
		bar = frame,
		cells = cells,
		icons = icons,
		hovers = hovers,
		selection = selection,
		top = bar,
		scaled = scaled,
		items = table.create(SLOTS, false),
		counts = table.create(SLOTS, 0),
		damages = table.create(SLOTS, 0),
		datas = table.create(SLOTS, false),
		keys = table.create(SLOTS, ""),
		keysStale = true,
		numbersShown = false,
		shownSelected = 0,
		shownMode = "hidden",
		activeAt = 0,
		fade = 0,
	}, Quickbar) :: any
	table.insert(built, self)
	if not keybindsHooked then
		keybindsHooked = true
		Keybinds.changed:Connect(function()
			for _, each in built do
				each.keysStale = true
			end
		end)
	end
	return self
end

-- Activity: the fade starts over (see the header).
function Quickbar.wake(self: Self, now: number)
	self.activeAt = now
end

-- The creative screen's hovered hotbar slot (nil: none).
function Quickbar.setHover(self: Self, slot: number?)
	for i, hover in self.hovers do
		Style.Dayz.setLit(hover, i == slot)
	end
end

-- (`base` transparency faded by `fade`: 0 keeps it, 1 is gone.)
local function faded(base: number, fade: number): number
	return 1 - (1 - base) * (1 - fade)
end

-- Writes the fade into the cells, numbers, selection and icons.
local function paintFade(self: Self, fade: number)
	local Dayz = Style.Dayz
	local cellAlpha = Dayz.Alpha.QuickCell
	for i, cell in self.cells do
		cell.base.BackgroundTransparency = faded(cellAlpha, fade)
		local occupied = self.items[i] ~= false
		local suffix = if occupied then "" else "Empty"
		cell.box.BackgroundTransparency = faded(Dayz.Alpha["QuickNumberBox" .. suffix], fade)
		cell.digit.TextTransparency = faded(Dayz.Alpha["QuickNumberText" .. suffix], fade)
		local stroke = cell.box:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = faded(Dayz.Alpha["QuickNumberLine" .. suffix], fade)
		end
		self.icons[i]:setTransparency(fade)
	end
	local ring = self.selection:FindFirstChild("Outline")
	local stroke = ring and ring:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = faded(Dayz.Alpha.Outline, fade)
	end
end

--[[
	Draws this frame: the nine stacks of `window`'s inventory (nil: none), `selected` (1..9) and
	the fade (see the header; `active`: something keeps the bar awake).
]]
function Quickbar.render(self: Self, now: number, mode: Mode, window: Types.Window?, selected: number, active: boolean)
	-- (Faces and numbers are painted again only for a slot that changed, or all of them when the
	-- selection, the mode, the keys or the numbers' visibility did.)
	local repaint = self.keysStale
	if self.keysStale then
		readKeys(self)
	end
	local inventory = if window then window.inventory else nil
	local changed = mode ~= self.shownMode or selected ~= self.shownSelected
	local showNumbers = not UiScale.touch() and Style.Theme.Text.tiny * self.scaled.scale >= NUMBER_MIN_PX
	if changed or showNumbers ~= self.numbersShown then
		self.numbersShown = showNumbers
		repaint = true
	end
	for i = 1, SLOTS do
		local stack = if inventory then inventory.slots[i] else nil
		local item: number | false = if stack then stack.item else false
		local count = if stack then stack.count else 0
		local damage = if stack then stack.damage or 0 else 0
		local data: Items.Data | false = if stack and stack.data then stack.data else false
		local slotChanged = item ~= self.items[i]
		if slotChanged or count ~= self.counts[i] or damage ~= self.damages[i] or data ~= self.datas[i] then
			self.items[i], self.counts[i], self.damages[i], self.datas[i] = item, count, damage, data
			self.icons[i]:set(
				if stack then stack.item else nil,
				if stack then stack.count else nil,
				if stack then stack.damage else nil,
				if stack then stack.data else nil
			)
			changed = true
		end
		if repaint or slotChanged then
			local occupied = item ~= false
			local cell = self.cells[i]
			Style.Dayz.paintFace(cell.face, if i == selected then "selected" elseif occupied then "filled" else "empty")
			Style.Dayz.paintNumber(cell, if showNumbers then self.keys[i] else "", occupied)
		end
	end
	if selected ~= self.shownSelected then
		self.selection.Position = UDim2.fromOffset(-1 + HudLayout.QUICK_STEP * (selected - 1), self.top - 1)
	end
	self.shownSelected, self.shownMode = selected, mode
	-- The fade (off by default).
	local after = Config.Ui.QuickbarFadeAfter
	if changed or active or mode ~= "play" then
		self.activeAt = now
	end
	local fade = 0
	if after > 0 then
		local into = now - self.activeAt - after
		if into > 0 then
			local time = math.max(Config.Ui.QuickbarFadeTime, 1e-3)
			fade = math.clamp(into / time, 0, 1) * Config.Ui.QuickbarFadeTo
		end
	end
	if fade ~= self.fade then
		self.fade = fade
		paintFade(self, fade)
	elseif fade > 0 and changed then
		-- (A number box that just changed state took its unfaded look.)
		paintFade(self, fade)
	end
end

return Quickbar
