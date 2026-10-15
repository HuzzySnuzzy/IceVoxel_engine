--!strict
--[[
	JEI's item list: every item (Items.list order) in a grid, a page at a time, while an inventory
	screen is open. Drawn in the inventory family's survival look (Style.Dayz): flat dark buttons,
	soft text, the items as a catalogue (no slot faces or grid lines: dayz icons, a white outline
	on the hovered one).

	  page row  "<" and ">" turn the pages (wrapping around, like JEI), "n / m" between them (just
	            "n" where that does not fit); the mouse wheel over the list turns them too
	  grid      the items of the page; hovering lights one up
	  search    a text field at the bottom: the list shows the items whose name contains the text
	            (JeiData.filter, Items.search) as you type; the text turns the warning red when
	            nothing matches. While it has focus, keys are text (Ui/Screens ignores keys while a
	            TextBox is focused), so E, Q and the number keys do nothing else

	Where it goes is Jei/JeiLayout's: docked in the survival inventory's ITEMS section (whose dark
	body is behind it: the list draws no background of its own) or beside the creative screen's
	panel (on its own dark Panel). `setLayout` moves its parts whenever the placement changes
	(JeiLayout.samePlacement) and rebuilds the cells only when their columns or rows change
	(JeiLayout.sameCells); the same layout table again does nothing. Clicks and keys on items are
	the controller's (Ui/Jei): this module draws, pages and hit-tests (screen pixels, the
	InputObject.Position space).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)

local SoundPlayer = require(script.Parent.Parent.Parent.Audio.SoundPlayer)
local HoverTip = require(script.Parent.Parent.HoverTip)
local ItemIcon = require(script.Parent.Parent.ItemIcon)
local Style = require(script.Parent.Parent.Style)
local Theme = require(script.Parent.Parent.Theme)
local JeiData = require(script.Parent.JeiData)
local JeiLayout = require(script.Parent.JeiLayout)

local Dayz = Style.Dayz

type Cell = { button: TextButton, icon: ItemIcon.ItemIcon, hover: Frame, item: number? }

export type JeiPanel = {
	root: Frame,
	search: TextBox,
	setLayout: (self: JeiPanel, layout: JeiLayout.ListLayout?) -> (),
	setVisible: (self: JeiPanel, visible: boolean) -> (),
	render: (self: JeiPanel, hovered: number?) -> (),
	turn: (self: JeiPanel, delta: number) -> (),
	itemAt: (self: JeiPanel, point: Vector2) -> number?,
	itemOf: (self: JeiPanel, object: GuiObject) -> number?,
	covers: (self: JeiPanel, point: Vector2) -> boolean,
	firstSelectable: (self: JeiPanel) -> GuiObject?,
	releaseFocus: (self: JeiPanel) -> (),
}

type Self = JeiPanel & {
	scale: UIScale,
	scaled: Style.Scaled,
	back: Frame,
	grid: Frame,
	pageLabel: TextLabel,
	prev: TextButton,
	next: TextButton,
	fieldHolder: Frame,
	cells: { Cell },
	byButton: { [GuiObject]: Cell },
	columns: number,
	rows: number,
	-- The layout shown (nil: none yet).
	layout: JeiLayout.ListLayout?,
	filtered: { Items.ItemDef },
	page: number,
	-- What the cells show (page and list), to redraw only on a change.
	shownPage: number,
	shownList: { Items.ItemDef }?,
	shown: boolean,
	fits: boolean,
}

local JeiPanel = {}
JeiPanel.__index = JeiPanel

-- Width (GUI pixels) of a page text, in the look's font.
local function measure(text: string): number
	return Style.textWidth(text, Theme.Text.small, Dayz.FONT)
end

local function perPage(self: Self): number
	return self.columns * self.rows
end

local function pageCount(self: Self): number
	return JeiData.pageCount(#self.filtered, perPage(self))
end

function JeiPanel.new(parent: Instance): JeiPanel
	local root = Instance.new("Frame")
	root.Name = "JeiList"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.ZIndex = 2
	root.Parent = parent
	local scale = Instance.new("UIScale")
	scale.Parent = root
	local scaled = Dayz.scaled()

	-- Its own dark panel beside the creative screen (docked, the ITEMS body is behind it).
	local back = Style.frame(root, 0, 0, 0, 0, Dayz.Colour.Panel, 0)
	back.Name = "Back"
	back.BackgroundTransparency = Dayz.Alpha.Panel
	back.Size = UDim2.fromScale(1, 1)
	back.Visible = false
	Dayz.outline(back, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(0, JeiLayout.NAV_HEIGHT)
	grid.ZIndex = 1
	grid.Parent = root

	local prev = Dayz.button(root, "<", 0, 1, JeiLayout.ARROW_W, JeiLayout.ARROW_H, 4, scaled)
	local nextButton = Dayz.button(root, ">", 0, 1, JeiLayout.ARROW_W, JeiLayout.ARROW_H, 4, scaled)
	local label = Dayz.label(root, "", 0, 3, 0, 8, "small", Dayz.Colour.TextSoft, 4, Enum.TextXAlignment.Center, scaled)

	-- The search field lives in a holder so it can move with the layout.
	local holder = Instance.new("Frame")
	holder.Name = "Search"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromOffset(0, 12)
	holder.ZIndex = 3
	holder.Parent = root

	local self = (
		setmetatable({
			root = root,
			scale = scale,
			scaled = scaled,
			back = back,
			grid = grid,
			pageLabel = label,
			prev = prev,
			next = nextButton,
			fieldHolder = holder,
			cells = {},
			byButton = {},
			columns = 0,
			rows = 0,
			layout = nil,
			filtered = Items.list,
			page = 1,
			shownPage = -1,
			shownList = nil,
			shown = false,
			fits = false,
		}, JeiPanel) :: any
	) :: Self

	-- (setLayout resizes its frame to the list's width.)
	self.search = Dayz.field(holder, 0, 0, 100, "Search...", 1, scaled)
	self.search:GetPropertyChangedSignal("Text"):Connect(function()
		self.filtered = JeiData.filter(self.search.Text)
		self.page = 1
		local nothing = #self.filtered == 0 and self.search.Text ~= ""
		self.search.TextColor3 = if nothing then Dayz.Colour.Warning else Dayz.Colour.Text
	end)

	prev.Activated:Connect(function()
		SoundPlayer.click()
		self:turn(-1)
	end)
	nextButton.Activated:Connect(function()
		SoundPlayer.click()
		self:turn(1)
	end)
	HoverTip.attach(prev, "jei.previous")
	HoverTip.attach(nextButton, "jei.next")
	HoverTip.attach(self.search, "jei.search")
	return self
end

local function clearCells(self: Self)
	for _, cell in self.cells do
		cell.icon:destroy()
		cell.button:Destroy()
	end
	self.cells = {}
	self.byButton = {}
end

-- Resizes the search field's frame to `width` (keeping the TextBox and its text).
local function sizeField(self: Self, width: number)
	local box = self.search
	local frame = box.Parent
	if frame and frame:IsA("Frame") then
		frame.Size = UDim2.fromOffset(width, 12)
	end
	box.Size = UDim2.fromOffset(math.max(0, width - 6), 12)
	self.fieldHolder.Size = UDim2.fromOffset(width, 12)
end

-- Builds the grid's cells for `layout` (columns x rows of the catalogue).
local function buildCells(self: Self, layout: JeiLayout.ListLayout)
	clearCells(self)
	for row = 0, layout.rows - 1 do
		for column = 0, layout.columns - 1 do
			local x, y = 1 + column * JeiLayout.SLOT, 1 + row * JeiLayout.SLOT
			local button = Style.itemButton(self.grid, x, y, 4)
			local icon = ItemIcon.new(button, 1, 1, 5, "dayz", self.scaled)
			local hover = Instance.new("Frame")
			hover.Name = "Hover"
			hover.BackgroundTransparency = 1
			hover.BorderSizePixel = 0
			hover.Position = UDim2.fromOffset(1, 1)
			hover.Size = UDim2.fromOffset(Theme.Size.CELL, Theme.Size.CELL)
			hover.ZIndex = 10
			hover.Visible = false
			Dayz.outline(hover, nil, nil, self.scaled)
			hover.Parent = button
			local cell: Cell = { button = button, icon = icon, hover = hover, item = nil }
			table.insert(self.cells, cell)
			self.byButton[button] = cell
		end
	end
	self.shownPage = -1
end

--[[
	Places the list (Jei/JeiLayout; nil hides it: no room). Its parts move whenever the placement
	changes; its cells are rebuilt only when the grid's columns or rows change.
]]
function JeiPanel.setLayout(self: Self, layout: JeiLayout.ListLayout?)
	self.fits = layout ~= nil
	local visible = layout ~= nil and self.shown
	if self.root.Visible ~= visible then
		self.root.Visible = visible
	end
	if layout == nil then
		-- (No room: a search field keeping its focus out of sight would swallow every key.)
		self:releaseFocus()
		return
	end
	local old = self.layout
	if layout == old then
		return
	end
	self.layout = layout
	local placed = old ~= nil and JeiLayout.samePlacement(old, layout)
	local cells = old ~= nil and JeiLayout.sameCells(old, layout)
	if placed and cells then
		return
	end
	if not placed then
		if self.scale.Scale ~= layout.scale then
			self.scale.Scale = layout.scale
		end
		self.scaled:setScale(layout.scale)
		self.root.Position = UDim2.fromOffset(math.floor(layout.x), math.floor(layout.y))
		self.root.Size = UDim2.fromOffset(layout.width, layout.height)
		self.back.Visible = not layout.docked
		local parts = JeiLayout.listParts(layout)
		self.prev.Position = UDim2.fromOffset(parts.prev.x, parts.prev.y)
		self.next.Position = UDim2.fromOffset(parts.next.x, parts.next.y)
		self.pageLabel.Position = UDim2.fromOffset(parts.page.x, parts.page.y)
		self.pageLabel.Size = UDim2.fromOffset(parts.page.w, parts.page.h)
		self.grid.Position = UDim2.fromOffset(parts.grid.x, parts.grid.y)
		self.grid.Size = UDim2.fromOffset(parts.grid.w, parts.grid.h)
		self.fieldHolder.Position = UDim2.fromOffset(parts.search.x, parts.search.y)
		sizeField(self, parts.search.w)
		-- (The page text's room may have changed.)
		self.shownPage = -1
	end
	if not cells then
		self.columns, self.rows = layout.columns, layout.rows
		buildCells(self, layout)
	end
end

-- Shows or hides the list (while a screen is open); it stays hidden where it does not fit.
function JeiPanel.setVisible(self: Self, visible: boolean)
	self.shown = visible
	self.root.Visible = visible and self.fits
	if not visible then
		self:releaseFocus()
	end
end

-- Turns `delta` pages (wrapping around).
function JeiPanel.turn(self: Self, delta: number)
	self.page = JeiData.turn(self.page, delta, pageCount(self))
end

-- Draws the page (only when it or the filter changed) and the outline on `hovered`.
function JeiPanel.render(self: Self, hovered: number?)
	if not self.root.Visible then
		return
	end
	local pages = pageCount(self)
	self.page = math.clamp(self.page, 1, pages)
	if self.page ~= self.shownPage or self.filtered ~= self.shownList then
		self.shownPage = self.page
		self.shownList = self.filtered
		local first = (self.page - 1) * perPage(self)
		for i, cell in self.cells do
			local def = self.filtered[first + i]
			cell.item = if def then def.id else nil
			cell.icon:set(cell.item, 1)
			cell.button.Selectable = def ~= nil
		end
		self.pageLabel.Text = JeiLayout.pageText(self.page, pages, self.pageLabel.Size.X.Offset, measure)
	end
	for _, cell in self.cells do
		Dayz.setLit(cell.hover, cell.item ~= nil and cell.item == hovered)
	end
end

-- The item under `point` (screen pixels), if any.
function JeiPanel.itemAt(self: Self, point: Vector2): number?
	if not self.root.Visible then
		return nil
	end
	for _, cell in self.cells do
		if cell.item and Style.contains(cell.button, point) then
			return cell.item
		end
	end
	return nil
end

-- The item of a (gamepad) selected cell.
function JeiPanel.itemOf(self: Self, object: GuiObject): number?
	local cell = self.byButton[object]
	return if cell then cell.item else nil
end

-- Is `point` over the list (its page row, grid or search field)?
function JeiPanel.covers(self: Self, point: Vector2): boolean
	return self.root.Visible and Style.contains(self.root, point)
end

function JeiPanel.firstSelectable(self: Self): GuiObject?
	local first = self.cells[1]
	return if first and first.item then first.button else nil
end

function JeiPanel.releaseFocus(self: Self)
	if self.search:IsFocused() then
		self.search:ReleaseFocus()
	end
end

return JeiPanel
