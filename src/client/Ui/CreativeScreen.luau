--!strict
--[[
	The creative inventory's "Item selection" panel (Minecraft Pocket Edition's), drawn in the
	inventory family's survival look (Ui/Theme, Style.Dayz):

	  * a dark Panel (with a hairline) under a black bar titled "ITEM SELECTION" (a body-less
	    Style.Dayz.section, so it is the inventory's section bar; the touch close button at its
	    right end), a search field (filters with Items.search as you type; while it has focus,
	    keys type instead of acting);
	  * a grid of every item (Items.list, filtered), 8 columns and 5 rows, as a catalogue: no slot
	    faces or grid lines, the dayz item pictures, a white outline on the hovered one; a flat
	    scrollbar (the mouse wheel scrolls a row at a time, the thumb can be dragged or the track
	    clicked, and on touch screens the grid scrolls with the finger);
	  * the hotbar row underneath is the real one: the HUD's quickbar stays on screen below the
	    panel and its slots are clicked like inventory slots (Ui/Hud, mode "creative");
	  * tabs above the panel switch to the inventory screen (armor, crafting and the rest) and back.

	Layout and API are Minecraft's as before (176 x 130 under the 26 px tabs; the grid at (8, 34),
	the scrollbar's track at (154, 33), 14 x 90). The grid only has as many slot widgets as are
	visible; scrolling changes which items they show. Clicks are Ui/SlotClicks (grid targets: full
	stacks, deleting carried ones), driven by Ui/Screens; this module draws and hit-tests (screen
	pixels, the InputObject.Position space). Outlines and text weights follow the GUI scale Ui/Screens
	gives the root (its UIScale, read when it changes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local Hud = require(script.Parent.Hud)
local HoverTip = require(script.Parent.HoverTip)
local ItemIcon = require(script.Parent.ItemIcon)
local SlotClicks = require(script.Parent.SlotClicks)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

type Window = Types.Window
type Target = SlotClicks.Target

local Dayz = Style.Dayz

local WIDTH = 176
local PANEL_HEIGHT = 130
local TOP = ItemIcon.TAB_HEIGHT
local COLUMNS, ROWS = 8, 5
-- Item position of the grid's first slot.
local GRID_X, GRID_Y = 8, 34
-- The title bar and its touch close button, the search field.
local BAR_H = Theme.Size.SECTION_HEADER
local CLOSE = 12
local SEARCH_X, SEARCH_Y = 7, 17
-- The scrollbar's track; its thumb is Style.Dayz.scrollbar's (Theme's THUMB_H tall).
local TRACK_X, TRACK_Y, TRACK_W, TRACK_H = 154, 33, 14, 90

type Cell = { view: ItemIcon.Slot, item: number }

export type CreativeScreen = {
	root: Frame,
	onTab: () -> (),
	onClose: () -> (),
	size: (self: CreativeScreen) -> Vector2,
	render: (self: CreativeScreen, window: Window, hover: Target?, dragged: { [number]: boolean }) -> (),
	targetAt: (self: CreativeScreen, point: Vector2) -> Target?,
	targetOf: (self: CreativeScreen, object: GuiObject) -> Target?,
	firstSelectable: (self: CreativeScreen) -> GuiObject?,
	inGrid: (self: CreativeScreen, point: Vector2) -> boolean,
	scrollBy: (self: CreativeScreen, rows: number) -> (),
	rowPixels: (self: CreativeScreen) -> number,
	pointerDown: (self: CreativeScreen, point: Vector2) -> boolean,
	pointerMove: (self: CreativeScreen, point: Vector2) -> (),
	pointerUp: (self: CreativeScreen) -> (),
	releaseFocus: (self: CreativeScreen) -> (),
	typing: (self: CreativeScreen) -> boolean,
}

type Self = CreativeScreen & {
	panel: Frame,
	tabFrames: { GuiObject },
	search: TextBox,
	cells: { Cell },
	byButton: { [GuiObject]: Cell },
	scrollbar: Style.Scrollbar,
	scaled: Style.Scaled,
	-- The root's UIScale (Ui/Screens'), found once it is there.
	uiScale: UIScale?,
	filtered: { Items.ItemDef },
	-- Rows scrolled (fractional while dragging / swiping; the grid shows the nearest row).
	scroll: number,
	shownRow: number,
	shownList: { Items.ItemDef }?,
	draggingThumb: boolean,
	hotbarBase: number,
}

local CreativeScreen = {}
CreativeScreen.__index = CreativeScreen

local function itemNamed(name: string): number?
	local ok, id = pcall(function()
		return Items.id[name]
	end)
	return if ok then id else nil
end

local function maxRow(self: Self): number
	return math.max(0, math.ceil(#self.filtered / COLUMNS) - ROWS)
end

function CreativeScreen.new(parent: Instance): CreativeScreen
	local root = Instance.new("Frame")
	root.Name = "Creative"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Size = UDim2.fromOffset(WIDTH, TOP + PANEL_HEIGHT)
	root.Visible = false
	root.Parent = parent
	Dayz.mark(root)
	local scaled = Dayz.scaled()

	local self = (
		setmetatable({
			root = root,
			onTab = function() end,
			onClose = function() end,
			cells = {},
			byButton = {},
			scaled = scaled,
			uiScale = nil,
			filtered = Items.list,
			scroll = 0,
			shownRow = -1,
			shownList = nil,
			draggingThumb = false,
			-- Window 0's hotbar (after its 2 x 2 grid); render() follows the window shown.
			hotbarBase = Menu.windowIndex(Types.newWindow(Types.newInventory()), "inventory", 1) :: number,
		}, CreativeScreen) :: any
	) :: Self

	-- Tabs: this screen (active) and the inventory.
	local thisTab = ItemIcon.tab(root, 0, itemNamed("Grass"), true, scaled)
	local inventoryTab = ItemIcon.tab(root, ItemIcon.TAB_WIDTH + 1, itemNamed("Chest"), false, scaled)
	self.tabFrames =
		table.move(inventoryTab.frames, 1, #inventoryTab.frames, #thisTab.frames + 1, table.clone(thisTab.frames))
	inventoryTab.button.Activated:Connect(function()
		SoundPlayer.click()
		self.onTab()
	end)
	HoverTip.attach(inventoryTab.button, "creative.inventoryTab")

	local panel = Style.frame(root, 0, TOP, WIDTH, PANEL_HEIGHT, Dayz.Colour.Panel, 1)
	panel.Name = "Items"
	panel.BackgroundTransparency = Dayz.Alpha.Panel
	panel.Active = true
	Dayz.outline(panel, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
	self.panel = panel

	-- The title bar (a body-less Style.Dayz.section, drawn as the inventory's section bars: black,
	-- the title in capitals) and the touch close button.
	local titleBar = Dayz.section(panel, "Item selection", { face = "none", scaled = scaled })
	titleBar.root.Name = "TitleBar"
	titleBar:place(0, 0, WIDTH, BAR_H, 0)
	local close = Dayz.button(panel, "x", WIDTH - CLOSE - 1, 1, CLOSE, CLOSE, 6, scaled)
	close.Visible = UserInputService.TouchEnabled
	close.Activated:Connect(function()
		SoundPlayer.click()
		self.onClose()
	end)
	HoverTip.attach(close, "creative.close")

	local search = Dayz.field(panel, SEARCH_X, SEARCH_Y, WIDTH - 2 * SEARCH_X, "Search...", 5, scaled)
	self.search = search
	search:GetPropertyChangedSignal("Text"):Connect(function()
		self.filtered = Items.search(search.Text)
		self.scroll = 0
	end)

	-- The grid: a catalogue (faces stay unfilled, no lines), outlined when hovered.
	for row = 0, ROWS - 1 do
		for column = 0, COLUMNS - 1 do
			local view = ItemIcon.slot(panel, GRID_X + column * 18, GRID_Y + row * 18, nil, false, scaled)
			local cell: Cell = { view = view, item = 0 }
			table.insert(self.cells, cell)
			self.byButton[view.button] = cell
		end
	end

	self.scrollbar = Dayz.scrollbar(panel, TRACK_X, TRACK_Y, TRACK_W, TRACK_H, 4)

	return self
end

function CreativeScreen.size(_self: Self): Vector2
	return Vector2.new(WIDTH, TOP + PANEL_HEIGHT)
end

-- Scrolls by `rows` (positive: down the list), clamped.
function CreativeScreen.scrollBy(self: Self, rows: number)
	self.scroll = math.clamp(self.scroll + rows, 0, maxRow(self))
end

-- Screen pixels per grid row (for touch scrolling).
function CreativeScreen.rowPixels(self: Self): number
	local first = self.cells[1]
	local pixels = if first then first.view.button.AbsoluteSize.Y else 0
	return if pixels > 0 then pixels else 18
end

local function scrollTo(self: Self, point: Vector2)
	-- (Minecraft centres the thumb on the pointer.)
	local track = self.scrollbar.track
	local position, size = track.AbsolutePosition, track.AbsoluteSize
	local pixels = size.Y / TRACK_H
	local thumb = math.min(Theme.Size.THUMB_H, TRACK_H) * pixels
	local span = size.Y - thumb
	if span <= 0 then
		return
	end
	local fraction = math.clamp((point.Y - position.Y - thumb / 2) / span, 0, 1)
	self.scroll = fraction * maxRow(self)
end

-- A press on the scrollbar starts dragging it (true: the press is taken).
function CreativeScreen.pointerDown(self: Self, point: Vector2): boolean
	if not self.root.Visible or not Style.contains(self.scrollbar.track, point) then
		return false
	end
	self.draggingThumb = true
	scrollTo(self, point)
	return true
end

function CreativeScreen.pointerMove(self: Self, point: Vector2)
	if self.draggingThumb then
		scrollTo(self, point)
	end
end

-- The thumb (or a finger scrolling the grid) let go: settle on the row shown.
function CreativeScreen.pointerUp(self: Self)
	self.draggingThumb = false
	self.scroll = math.floor(self.scroll + 0.5)
end

-- Is `point` over the item grid (touches there scroll it)?
function CreativeScreen.inGrid(self: Self, point: Vector2): boolean
	local first, last = self.cells[1], self.cells[#self.cells]
	if first == nil or last == nil then
		return false
	end
	local a, b = first.view.button, last.view.button
	local min, max = a.AbsolutePosition, b.AbsolutePosition + b.AbsoluteSize
	return point.X >= min.X and point.Y >= min.Y and point.X < max.X and point.Y < max.Y
end

function CreativeScreen.typing(self: Self): boolean
	return self.search:IsFocused()
end

function CreativeScreen.releaseFocus(self: Self)
	if self.search:IsFocused() then
		self.search:ReleaseFocus()
	end
end

function CreativeScreen.render(self: Self, window: Window, hover: Target?, dragged: { [number]: boolean })
	-- (Outlines and text weights follow the scale Ui/Screens gives the root.)
	local uiScale = self.uiScale
	if uiScale == nil then
		local found = self.root:FindFirstChildOfClass("UIScale")
		uiScale = found
		self.uiScale = found
	end
	if uiScale then
		self.scaled:setScale(uiScale.Scale)
	end
	self.hotbarBase = Menu.windowIndex(window, "inventory", 1) or self.hotbarBase
	self.scroll = math.clamp(self.scroll, 0, maxRow(self))
	local row = math.floor(self.scroll + 0.5)
	if row ~= self.shownRow or self.filtered ~= self.shownList then
		self.shownRow = row
		self.shownList = self.filtered
		for i, cell in self.cells do
			local def = self.filtered[row * COLUMNS + i]
			cell.item = if def then def.id else 0
			cell.view.icon:set(if def then def.id else nil, 1)
		end
	end
	local hovered = if hover and hover.kind == "grid" and hover.item ~= 0 then hover.item else -1
	for _, cell in self.cells do
		Dayz.setLit(cell.view.hover, cell.item == hovered)
	end

	-- The HUD's hotbar is this screen's hotbar row.
	local slot: number? = nil
	if hover and hover.kind == "slot" then
		local h = hover.index - self.hotbarBase + 1
		if h >= 1 and h <= Types.HOTBAR_SIZE then
			slot = h
		end
	end
	if slot == nil then
		for h = 1, Types.HOTBAR_SIZE do
			if dragged[self.hotbarBase + h - 1] then
				slot = h
				break
			end
		end
	end
	Hud.setHover(slot)

	local rows = maxRow(self)
	self.scrollbar:place(if rows > 0 then self.scroll / rows else 0, rows > 0)
end

-- What is under `point`: a grid item, a hotbar slot, nil over the panel, or outside.
function CreativeScreen.targetAt(self: Self, point: Vector2): Target?
	for _, cell in self.cells do
		if Style.contains(cell.view.button, point) then
			return { kind = "grid", item = cell.item }
		end
	end
	for h = 1, Types.HOTBAR_SIZE do
		if Style.contains(Hud.hotbarCell(h), point) then
			return { kind = "slot", index = self.hotbarBase + h - 1 }
		end
	end
	if Style.contains(self.panel, point) then
		return nil
	end
	for _, frame in self.tabFrames do
		if Style.contains(frame, point) then
			return nil
		end
	end
	-- Between the hotbar's cells, or its touch button.
	if Hud.covers(point) then
		return nil
	end
	return { kind = "outside" }
end

function CreativeScreen.targetOf(self: Self, object: GuiObject): Target?
	local cell = self.byButton[object]
	if cell then
		return { kind = "grid", item = cell.item }
	end
	for h = 1, Types.HOTBAR_SIZE do
		if Hud.hotbarCell(h) == object then
			return { kind = "slot", index = self.hotbarBase + h - 1 }
		end
	end
	return nil
end

function CreativeScreen.firstSelectable(self: Self): GuiObject?
	local first = self.cells[1]
	return if first then first.view.button else nil
end

return CreativeScreen
