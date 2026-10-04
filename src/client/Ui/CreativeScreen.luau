--!strict
--[[
	The creative inventory, old-school: Minecraft Pocket Edition's "Item selection" panel.

	  * a gray beveled panel titled "Item selection" with a search box (filters with Items.search
	    as you type; while it has focus, keys type instead of acting);
	  * a grid of every item (Items.list, filtered), 8 columns and 5 rows of slots, with a
	    Minecraft-style scrollbar: the mouse wheel scrolls it a row at a time, the thumb can be
	    dragged (or the track clicked), and on touch screens the grid scrolls with the finger;
	  * the hotbar row underneath is the real one: the HUD's hotbar stays on screen below the panel
	    and its slots are clicked like inventory slots (Ui/Hud, mode "creative");
	  * tabs above the panel switch to the inventory screen (armor, the 2 x 2 crafting grid and the
	    rest) and back.

	The grid only has as many slot widgets as are visible; scrolling changes which items they
	show. Clicks are Ui/SlotClicks (grid targets: full stacks, deleting carried ones), driven by
	Ui/Screens; this module draws and hit-tests (screen pixels, the InputObject.Position space).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local Hud = require(script.Parent.Hud)
local ItemIcon = require(script.Parent.ItemIcon)
local SlotClicks = require(script.Parent.SlotClicks)
local Style = require(script.Parent.Style)

type Window = Types.Window
type Target = SlotClicks.Target

local WIDTH = 176
local PANEL_HEIGHT = 130
local TOP = ItemIcon.TAB_HEIGHT
local COLUMNS, ROWS = 8, 5
-- Item position of the grid's first slot.
local GRID_X, GRID_Y = 8, 34
-- The scrollbar: its track (inset) and thumb (Minecraft's 12 x 15 scroller).
local TRACK_X, TRACK_Y, TRACK_W, TRACK_H = 154, 33, 14, 90
local THUMB_W, THUMB_H = 12, 15

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
	track: Frame,
	thumb: Frame,
	thumbFace: Frame,
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

	local self = (
		setmetatable({
			root = root,
			onTab = function() end,
			onClose = function() end,
			cells = {},
			byButton = {},
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
	local thisTab = ItemIcon.tab(root, 0, itemNamed("Grass"), true)
	local inventoryTab = ItemIcon.tab(root, ItemIcon.TAB_WIDTH + 1, itemNamed("Chest"), false)
	self.tabFrames =
		table.move(inventoryTab.frames, 1, #inventoryTab.frames, #thisTab.frames + 1, table.clone(thisTab.frames))
	inventoryTab.button.Activated:Connect(function()
		SoundPlayer.click()
		self.onTab()
	end)

	local panel = Style.panel(root, 0, TOP, WIDTH, PANEL_HEIGHT)
	panel.Name = "Items"
	self.panel = panel
	Style.text(panel, "Item selection", 8, 6, 140, 8, Style.Colour.Title, 5)

	local close = Style.button(panel, "x", WIDTH - 15, 3, 12, 12, 6)
	close.Visible = UserInputService.TouchEnabled
	close.Activated:Connect(function()
		SoundPlayer.click()
		self.onClose()
	end)

	-- Search box: Minecraft's text field (black, gray border).
	Style.frame(panel, 7, 17, WIDTH - 14, 12, Style.Colour.FieldBorder, 4)
	-- (The field clips long text.)
	local field = Style.frame(panel, 8, 18, WIDTH - 16, 10, Style.Colour.Field, 5)
	field.ClipsDescendants = true
	local search = Instance.new("TextBox")
	search.Name = "Search"
	search.BackgroundTransparency = 1
	search.BorderSizePixel = 0
	search.Position = UDim2.fromOffset(2, 1)
	search.Size = UDim2.fromOffset(WIDTH - 20, 8)
	search.ClearTextOnFocus = false
	search.Font = Style.FONT
	search.TextSize = Style.TEXT_SIZE
	search.TextColor3 = Style.Colour.Text
	search.PlaceholderText = "Search..."
	search.PlaceholderColor3 = Color3.fromRGB(112, 112, 112)
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.TextYAlignment = Enum.TextYAlignment.Top
	search.Text = ""
	search.ZIndex = 1
	search.SelectionImageObject = Style.selectionImage
	search.Parent = field
	self.search = search
	search:GetPropertyChangedSignal("Text"):Connect(function()
		self.filtered = Items.search(search.Text)
		self.scroll = 0
	end)

	for row = 0, ROWS - 1 do
		for column = 0, COLUMNS - 1 do
			local view = ItemIcon.slot(panel, GRID_X + column * 18, GRID_Y + row * 18)
			local cell: Cell = { view = view, item = 0 }
			table.insert(self.cells, cell)
			self.byButton[view.button] = cell
		end
	end

	self.track = Style.inset(panel, TRACK_X, TRACK_Y, TRACK_W, TRACK_H, 4)
	local thumb = Style.frame(self.track, 1, 1, THUMB_W, THUMB_H, Style.Colour.PanelDark, 5)
	Style.frame(thumb, 0, 0, THUMB_W - 1, THUMB_H - 1, Style.Colour.PanelLight, 1)
	self.thumbFace = Style.frame(thumb, 1, 1, THUMB_W - 2, THUMB_H - 2, Style.Colour.Panel, 2)
	self.thumb = thumb

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
	-- Minecraft centres the thumb on the pointer.
	local position, size = self.track.AbsolutePosition, self.track.AbsoluteSize
	local pixels = size.Y / TRACK_H
	local thumb = THUMB_H * pixels
	local span = size.Y - 2 * pixels - thumb
	if span <= 0 then
		return
	end
	local fraction = math.clamp((point.Y - position.Y - pixels - thumb / 2) / span, 0, 1)
	self.scroll = fraction * maxRow(self)
end

-- A press on the scrollbar starts dragging it (true: the press is taken).
function CreativeScreen.pointerDown(self: Self, point: Vector2): boolean
	if not self.root.Visible or not Style.contains(self.track, point) then
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
		local lit = cell.item == hovered
		if cell.view.hover.Visible ~= lit then
			cell.view.hover.Visible = lit
		end
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
	local fraction = if rows > 0 then self.scroll / rows else 0
	self.thumb.Position = UDim2.fromOffset(1, 1 + math.floor((TRACK_H - 2 - THUMB_H) * fraction + 0.5))
	self.thumbFace.BackgroundColor3 = if rows > 0 then Style.Colour.Panel else Style.Colour.Slot
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
