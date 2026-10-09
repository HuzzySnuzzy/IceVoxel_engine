--!strict
--[[
	JEI's recipe view: the recipes or the uses of one item (Jei/JeiData groups), in a panel that
	takes the inventory panel's place (Minecraft's 176 x 166) while the item list stays beside it.

	  tabs      above the panel, one per category that has entries (crafting table, furnace, coal:
	            JEI's catalysts); the active one merges into the panel like the creative tabs
	  title     Back (when there is somewhere to go back to), the category's name, and the touch
	            close button
	  pages     "<" "n / m" ">" (wrapping); the mouse wheel over the panel turns them too
	  recipes   as many of the category as fit (Jei/JeiLayout):
	              crafting  the 3 x 3 grid (an ingredient a tag or several items accept shows each
	                        in turn, one a second; the looked-up item stays put), an arrow, the
	                        result and its count; the shapeless mark (tooltip "Shapeless"); and the
	                        "+" while a crafting grid is open: it moves the ingredients there
	                        (Jei/JeiTransfer), shift-click as many sets as there are. It is greyed
	                        out with the reason in its tooltip when the recipe is too big for the
	                        grid, items are missing or the inventory has no room for what is in
	                        the way; hovering it then shows the missing ingredients in red, like JEI
	              smelting  the input over a lit flame, the arrow filling over the 10 s it takes,
	                        the output, "10 s"
	              fuel      a flame burning down over the fuel's burn time, the fuel,
	                        "Burns 8 items" and the burn time
	              refining  the oil as a fluid stack (its colour in a slot, "Oil" and "1,000 mB"
	                        on hover), an arrow filling over the 5 s a bucket takes, the fuel,
	                        "5 s, 20 kJ" and "200 J/t"
	              heating, combustion  a flame burning down over a bucket's burn time, the lava
	                        or fuel as a fluid stack, "Makes 4 MJ" and "200 J/t for 1000 s"
	                        (fuel: "Makes 10 MJ" and "2.5 kJ/t for 200 s")
	            A fluid stack stands for its bucket in navigation (clicks, R / U, gamepad).

	A recipe the player may not make yet (Progression: a later Age's result; the controller's
	`setLocks`, JeiData.lockText) has its output greyed with a padlock on it; hovering the output
	adds what it needs ("Requires the Iron Age", `lockAt`), and its "+" is greyed with the same.

	Navigation (clicking items in it, R / U, Back, history) is the controller's (Ui/Jei): this
	module draws one state and hit-tests (screen pixels, the InputObject.Position space).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)

local SoundPlayer = require(script.Parent.Parent.Parent.Audio.SoundPlayer)
local HoverTip = require(script.Parent.Parent.HoverTip)
local ItemIcon = require(script.Parent.Parent.ItemIcon)
local MenuLayout = require(script.Parent.Parent.MenuLayout)
local Style = require(script.Parent.Parent.Style)
local JeiData = require(script.Parent.JeiData)
local JeiLayout = require(script.Parent.JeiLayout)
local JeiTransfer = require(script.Parent.JeiTransfer)
local TransmitterModel = require(script.Parent.Parent.Parent.Rendering.TransmitterModel)

type Entry = JeiData.Entry
type Group = JeiData.Group
type Rect = JeiLayout.Rect

export type Line = { text: string, colour: Color3 }

-- One recipe view: an item's recipes or uses, at a category and page.
export type State = {
	item: number,
	mode: JeiData.Mode,
	groups: { Group },
	category: number,
	page: number,
}

local WIDTH, HEIGHT = JeiLayout.VIEW_WIDTH, JeiLayout.VIEW_HEIGHT
local TAB_HEIGHT, TAB_WIDTH = ItemIcon.TAB_HEIGHT, ItemIcon.TAB_WIDTH
-- The red over a missing ingredient (JEI: 0x66FF0000 over the slot).
local MISSING_TRANSPARENCY = 0.6
local UNLIT_PALETTE: { [string]: Color3 } = {
	R = Style.Colour.Slot,
	O = Style.Colour.Slot,
	Y = Style.Colour.Slot,
	W = Style.Colour.Slot,
}
-- The padlock over a locked recipe's output (7 x 8): K outline, Y body, S shackle.
local PADLOCK_ART = {
	"..KKK..",
	".KSKSK.",
	".KS.SK.",
	"KKKKKKK",
	"KYYYYYK",
	"KYYKYYK",
	"KYYYYYK",
	"KKKKKKK",
}
local PADLOCK_PALETTE: { [string]: Color3 } = {
	K = Color3.fromRGB(40, 30, 10),
	Y = Color3.fromRGB(230, 180, 40),
	S = Color3.fromRGB(200, 200, 210),
}
-- JEI's shapeless mark: two arrows crossing over (9 x 10).
local SHAPELESS_ART = {
	".....#...",
	"......#..",
	"#########",
	"......#..",
	".....#...",
	"...#.....",
	"..#......",
	"#########",
	"..#......",
	"...#.....",
}

type CellWidget = { slot: ItemIcon.Slot, items: { number }?, cell: number, missing: Frame }
-- A fluid stack: a slot holding a square of the fluid's colour.
type FluidWidget = { slot: ItemIcon.Slot, stack: JeiData.FluidStack }

-- An animated sprite: grey art, with the lit art in a clipping frame that grows (Ui/InventoryScreen).
type Gauge = { clip: Frame, holder: Frame, rect: Rect, shown: number, vertical: boolean }

type EntryWidget = {
	entry: Entry,
	frame: Frame,
	cells: { CellWidget },
	fluids: { FluidWidget },
	output: ItemIcon.Slot?,
	-- The padlock over a locked output, and what the recipe needs (nil: not locked).
	padlock: Frame?,
	lock: string?,
	plus: TextButton?,
	setPlus: ((enabled: boolean) -> ())?,
	status: JeiTransfer.Status?,
	shapeless: Frame?,
	arrow: Gauge?,
	flame: Gauge?,
	-- Seconds one round of the gauge's animation takes.
	period: number,
}

type Tab = {
	category: JeiData.Category,
	active: Frame,
	inactive: Frame,
	-- The tab drawings (to hit-test) and the inactive one's button.
	activeArt: GuiObject,
	inactiveArt: GuiObject,
}

export type RecipeView = {
	root: Frame,
	-- Set by the controller.
	onBack: () -> (),
	onClose: () -> (),
	onTransfer: (entry: Entry, all: boolean) -> (),
	show: (self: RecipeView, state: State, canBack: boolean) -> (),
	state: (self: RecipeView) -> State?,
	size: (self: RecipeView) -> Vector2,
	turn: (self: RecipeView, delta: number) -> (),
	selectCategory: (self: RecipeView, index: number) -> (),
	setTransfer: (self: RecipeView, statusOf: (entry: Entry) -> JeiTransfer.Status?) -> (),
	setLocks: (self: RecipeView, lockOf: (entry: Entry) -> string?) -> (),
	refreshLocks: (self: RecipeView) -> (),
	lockAt: (self: RecipeView, point: Vector2) -> string?,
	refreshTransfer: (self: RecipeView) -> (),
	render: (self: RecipeView, now: number, point: Vector2?) -> (),
	itemAt: (self: RecipeView, point: Vector2) -> (number?, { number }?),
	fluidAt: (self: RecipeView, point: Vector2) -> JeiData.FluidStack?,
	itemOf: (self: RecipeView, object: GuiObject) -> number?,
	infoAt: (self: RecipeView, point: Vector2) -> { Line }?,
	covers: (self: RecipeView, point: Vector2) -> boolean,
	firstSelectable: (self: RecipeView) -> GuiObject?,
	hide: (self: RecipeView) -> (),
}

type Self = RecipeView & {
	panel: Frame,
	title: TextLabel,
	pageLabel: TextLabel,
	back: TextButton,
	close: TextButton,
	tabs: { Tab },
	current: State?,
	widgets: { EntryWidget },
	-- Every slot button of the page -> its icon (gamepad selection); a fluid stack's -> its bucket.
	byButton: { [GuiObject]: ItemIcon.ItemIcon },
	fluidButtons: { [GuiObject]: number },
	statusOf: ((entry: Entry) -> JeiTransfer.Status?)?,
	lockOf: ((entry: Entry) -> string?)?,
}

local RecipeView = {}
RecipeView.__index = RecipeView

local function itemNamed(name: string): number?
	return rawget(Items.id :: any, name)
end

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function newTab(self: Self, root: Frame, category: JeiData.Category)
	local item = itemNamed(JeiData.TAB_ITEMS[category])
	local function holder(active: boolean): Frame
		local frame = Instance.new("Frame")
		frame.Name = `{category}Tab`
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromOffset(TAB_WIDTH, TAB_HEIGHT + 4)
		-- (Sibling ZIndex: the active tab draws over the panel's border, the others behind it.)
		frame.ZIndex = if active then 2 else 0
		frame.Visible = false
		frame.Parent = root
		return frame
	end
	local active, inactive = holder(true), holder(false)
	local activeTab = ItemIcon.tab(active, 0, item, true)
	local inactiveTab = ItemIcon.tab(inactive, 0, item, false)
	activeTab.button.Selectable = false
	HoverTip.attach(activeTab.button, "jei.tab", category)
	HoverTip.attach(inactiveTab.button, "jei.tab", category)
	inactiveTab.button.Activated:Connect(function()
		local state = self.current
		if state == nil then
			return
		end
		for index, group in state.groups do
			if group.category == category then
				SoundPlayer.click()
				self:selectCategory(index)
				return
			end
		end
	end)
	table.insert(self.tabs, {
		category = category,
		active = active,
		inactive = inactive,
		activeArt = activeTab.frames[1],
		inactiveArt = inactiveTab.frames[1],
	})
end

function RecipeView.new(parent: Instance): RecipeView
	local root = Instance.new("Frame")
	root.Name = "Recipes"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(WIDTH, TAB_HEIGHT + HEIGHT)
	root.Visible = false
	root.ZIndex = 3
	root.Parent = parent

	local self = (
		setmetatable({
			root = root,
			onBack = function() end,
			onClose = function() end,
			onTransfer = function() end,
			tabs = {},
			current = nil,
			widgets = {},
			byButton = {},
			fluidButtons = {},
			statusOf = nil,
			lockOf = nil,
		}, RecipeView) :: any
	) :: Self

	for _, category in JeiData.CATEGORIES do
		newTab(self, root, category :: JeiData.Category)
	end

	local panel = Style.panel(root, 0, TAB_HEIGHT, WIDTH, HEIGHT)
	panel.Name = "Panel"
	self.panel = panel
	self.title =
		Style.text(panel, "", 0, JeiLayout.TITLE_Y, WIDTH, 8, Style.Colour.Title, 5, Enum.TextXAlignment.Center)
	self.pageLabel =
		Style.text(panel, "", 0, JeiLayout.PAGE_Y, WIDTH, 8, Style.Colour.Title, 5, Enum.TextXAlignment.Center)

	local b = JeiLayout.BACK
	self.back = Style.button(panel, "Back", b.x, b.y, b.w, b.h, 6)
	self.back.Activated:Connect(function()
		SoundPlayer.click()
		self.onBack()
	end)
	local c = JeiLayout.CLOSE
	self.close = Style.button(panel, "x", c.x, c.y, c.w, c.h, 6)
	self.close.Visible = UserInputService.TouchEnabled
	self.close.Activated:Connect(function()
		SoundPlayer.click()
		self.onClose()
	end)
	local p, n = JeiLayout.PREV, JeiLayout.NEXT
	local previous = Style.button(panel, "<", p.x, p.y, p.w, p.h, 6)
	previous.Activated:Connect(function()
		SoundPlayer.click()
		self:turn(-1)
	end)
	local following = Style.button(panel, ">", n.x, n.y, n.w, n.h, 6)
	following.Activated:Connect(function()
		SoundPlayer.click()
		self:turn(1)
	end)
	HoverTip.attach(self.back, "jei.back")
	HoverTip.attach(self.close, "jei.close")
	HoverTip.attach(previous, "jei.previousPage")
	HoverTip.attach(following, "jei.nextPage")
	return self
end

function RecipeView.size(_self: Self): Vector2
	return Vector2.new(WIDTH, TAB_HEIGHT + HEIGHT)
end

function RecipeView.state(self: Self): State?
	return self.current
end

--[[ Building a page ]]

local function newGauge(
	parent: Frame,
	rect: Rect,
	vertical: boolean,
	draw: (parent: Instance, lit: boolean) -> ()
): Gauge
	draw(parent, false)
	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Position = UDim2.fromOffset(rect.x, rect.y)
	clip.Size = UDim2.fromOffset(0, 0)
	clip.ZIndex = 6
	clip.Parent = parent
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(rect.w, rect.h)
	holder.ZIndex = 1
	holder.Parent = clip
	draw(holder, true)
	return { clip = clip, holder = holder, rect = rect, shown = -1, vertical = vertical }
end

-- Shows `shown` rows of a flame (from the bottom) or columns of an arrow (from the left).
local function setGauge(gauge: Gauge?, shown: number)
	if gauge == nil or gauge.shown == shown then
		return
	end
	gauge.shown = shown
	local rect = gauge.rect
	if gauge.vertical then
		gauge.clip.Position = UDim2.fromOffset(rect.x, rect.y + rect.h - shown)
		gauge.clip.Size = UDim2.fromOffset(rect.w, shown)
		gauge.holder.Position = UDim2.fromOffset(0, shown - rect.h)
	else
		gauge.clip.Size = UDim2.fromOffset(shown, rect.h)
	end
end

local function flameArt(rect: Rect): (parent: Instance, lit: boolean) -> ()
	return function(parent: Instance, lit: boolean)
		local x, y = if lit then 0 else rect.x, if lit then 0 else rect.y
		Style.pixelArt(parent, x, y, MenuLayout.FLAME_ART, if lit then Style.FirePalette else UNLIT_PALETTE, 5)
	end
end

local function arrowArt(rect: Rect): (parent: Instance, lit: boolean) -> ()
	return function(parent: Instance, lit: boolean)
		local x, y = if lit then 1 else rect.x + 1, if lit then 1 else rect.y + 1
		local art = MenuLayout.arrowArt(rect.w - 2, rect.h - 1)
		Style.pixelArt(parent, x, y, art, { ["#"] = if lit then Color3.new(1, 1, 1) else Style.Colour.Slot }, 5)
	end
end

local function buildEntry(self: Self, entry: Entry, x: number, y: number): EntryWidget
	local layout = JeiLayout.entry(entry.category)
	local frame = Instance.new("Frame")
	frame.Name = "Recipe"
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(layout.w, layout.h)
	frame.ZIndex = 4
	frame.Parent = self.panel
	local widget: EntryWidget = {
		entry = entry,
		frame = frame,
		cells = {},
		fluids = {},
		output = nil,
		padlock = nil,
		lock = nil,
		plus = nil,
		setPlus = nil,
		status = nil,
		shapeless = nil,
		arrow = nil,
		flame = nil,
		period = math.max(entry.ticks / 20, 0.5),
	}
	for index, spot in layout.inputs do
		local slot = ItemIcon.slot(frame, spot.x, spot.y, 4, spot.big)
		local missing = Style.frame(slot.button, 1, 1, Style.ITEM, Style.ITEM, Style.Colour.Missing, 9)
		missing.BackgroundTransparency = MISSING_TRANSPARENCY
		missing.Visible = false
		local cell: CellWidget = { slot = slot, items = entry.inputs[index], cell = index, missing = missing }
		table.insert(widget.cells, cell)
		self.byButton[slot.button] = slot.icon
	end
	-- Fluid stacks: what it takes, then what it makes.
	local function addFluid(spot: JeiLayout.Spot?, stack: JeiData.FluidStack?)
		if spot == nil or stack == nil then
			return
		end
		local slot = ItemIcon.slot(frame, spot.x, spot.y, 4, false)
		local rgb = TransmitterModel.fluidColour(stack.fluid)
		local fill = Style.frame(slot.button, 1, 1, Style.ITEM, Style.ITEM, Color3.fromRGB(rgb[1], rgb[2], rgb[3]), 5)
		fill.Name = "Fluid"
		table.insert(widget.fluids, { slot = slot, stack = stack })
		self.byButton[slot.button] = slot.icon
		local bucket = Fluids.bucketOf(stack.fluid)
		if bucket then
			self.fluidButtons[slot.button] = bucket
		end
	end
	local fluidInputs = entry.fluidInputs
	if fluidInputs then
		for i, stack in fluidInputs do
			addFluid(layout.fluidInputs[i], stack)
		end
	end
	addFluid(layout.fluidOutput, entry.fluidOutput)
	local out = layout.output
	local output = entry.output
	if out and output then
		local slot = ItemIcon.slot(frame, out.x, out.y, 4, out.big)
		slot.icon:set(output.item, output.count)
		widget.output = slot
		self.byButton[slot.button] = slot.icon
		-- (Shown while the recipe is locked: `refreshLocks`.)
		local padlock = Instance.new("Frame")
		padlock.Name = "Padlock"
		padlock.BackgroundTransparency = 1
		padlock.Position = UDim2.fromOffset(out.x + Style.ITEM - 7, out.y - 1)
		padlock.Size = UDim2.fromOffset(7, 8)
		padlock.ZIndex = 9
		padlock.Visible = false
		padlock.Parent = frame
		Style.pixelArt(padlock, 0, 0, PADLOCK_ART, PADLOCK_PALETTE, 1)
		widget.padlock = padlock
	end
	local arrow = layout.arrow
	if arrow then
		if entry.category == "smelting" or entry.category == "refining" then
			widget.arrow = newGauge(frame, arrow, false, arrowArt(arrow))
		else
			Style.pixelArt(
				frame,
				arrow.x,
				arrow.y,
				MenuLayout.arrowArt(arrow.w, arrow.h),
				{ ["#"] = Style.Colour.Slot },
				5
			)
		end
	end
	local flame = layout.flame
	if flame then
		if entry.category == "fuel" or entry.category == "heating" or entry.category == "combustion" then
			widget.flame = newGauge(frame, flame, true, flameArt(flame))
		else
			-- Smelting: the furnace is lit.
			Style.pixelArt(frame, flame.x, flame.y, MenuLayout.FLAME_ART, Style.FirePalette, 5)
		end
	end
	local mark = layout.shapeless
	if mark and entry.shapeless then
		local holder = Instance.new("Frame")
		holder.Name = "Shapeless"
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(mark.x, mark.y)
		holder.Size = UDim2.fromOffset(mark.w, mark.h)
		holder.ZIndex = 5
		holder.Parent = frame
		Style.pixelArt(holder, 0, 0, SHAPELESS_ART, { ["#"] = Style.Colour.Title }, 1)
		widget.shapeless = holder
	end
	local plus = layout.plus
	if plus and entry.recipe then
		local button, setEnabled = Style.toggleButton(frame, "+", plus.x, plus.y, plus.w, plus.h, 6)
		button.Visible = false
		button.Activated:Connect(function()
			local status = widget.status
			if status and status.ok then
				SoundPlayer.click()
				self.onTransfer(entry, shiftDown())
			end
		end)
		widget.plus = button
		widget.setPlus = setEnabled
	end
	local lines: { string } = {}
	if entry.category == "smelting" then
		lines = { JeiData.smeltText(entry.ticks) }
	elseif entry.category == "boiling" then
		lines = { JeiData.BOIL_TEXT }
	elseif entry.category == "fuel" then
		lines = { JeiData.fuelText(entry.ticks), JeiData.smeltText(entry.ticks) }
	elseif entry.fluidInputs then
		lines = JeiData.fluidTexts(entry)
	end
	for i, text in lines do
		local r = layout.texts[i]
		if r then
			local align = if entry.category == "smelting" or entry.category == "boiling"
				then Enum.TextXAlignment.Right
				else Enum.TextXAlignment.Left
			Style.text(frame, text, r.x, r.y, r.w, r.h, Style.Colour.Title, 5, align)
		end
	end
	return widget
end

local function clearPage(self: Self)
	for _, widget in self.widgets do
		for _, cell in widget.cells do
			cell.slot.icon:destroy()
		end
		for _, fluid in widget.fluids do
			fluid.slot.icon:destroy()
		end
		local output = widget.output
		if output then
			output.icon:destroy()
		end
		widget.frame:Destroy()
	end
	self.widgets = {}
	self.byButton = {}
	self.fluidButtons = {}
end

local function applyTransfer(self: Self)
	local statusOf = self.statusOf
	for _, widget in self.widgets do
		local plus, setPlus = widget.plus, widget.setPlus
		local status = if statusOf and widget.entry.recipe then statusOf(widget.entry) else nil
		widget.status = status
		if plus and setPlus then
			plus.Visible = status ~= nil
			setPlus(status ~= nil and status.ok)
		end
	end
end

-- Draws the current category's current page (tabs, title, page count, recipes); `canBack` (a new
-- state) shows or hides the Back button.
local function build(self: Self, canBack: boolean?)
	-- A gamepad selection in the view (a recipe's slot, a tab, Back) is destroyed or hidden by the
	-- rebuild: it moves to the new page's first slot, so the gamepad never loses its place.
	local selected = GuiService.SelectedObject
	local wasSelected = if selected and selected:IsDescendantOf(self.root) then selected else nil
	if canBack ~= nil then
		self.back.Visible = canBack
	end
	clearPage(self)
	local state = self.current
	if state == nil then
		return
	end
	local group = state.groups[state.category]
	local category: JeiData.Category = if group then group.category else "crafting"
	-- Tabs: one per category present, in order; the shown one active.
	local x = 0
	for _, tab in self.tabs do
		local present = false
		for _, g in state.groups do
			if g.category == tab.category then
				present = true
			end
		end
		local isActive = present and tab.category == category
		tab.active.Visible = isActive
		tab.inactive.Visible = present and not isActive
		if present then
			tab.active.Position = UDim2.fromOffset(x, 0)
			tab.inactive.Position = UDim2.fromOffset(x, 0)
			x += TAB_WIDTH + 1
		end
	end
	self.title.Text = JeiData.TITLES[category]
	local entries = if group then group.entries else {}
	local perPage = JeiLayout.perPage(category)
	local pages = JeiData.pageCount(#entries, perPage)
	state.page = math.clamp(state.page, 1, pages)
	self.pageLabel.Text = `{state.page} / {pages}`
	local first = (state.page - 1) * perPage
	local shown = math.min(perPage, #entries - first)
	for i = 1, shown do
		local ox, oy = JeiLayout.entryOrigin(category, i, shown)
		table.insert(self.widgets, buildEntry(self, entries[first + i], ox, oy))
	end
	applyTransfer(self)
	self:refreshLocks()
	if wasSelected and (wasSelected.Parent == nil or not Style.shown(wasSelected)) then
		GuiService.SelectedObject = self:firstSelectable()
	end
end

--[[ Public ]]

-- Shows a state (the controller keeps the history; `canBack` shows the Back button).
function RecipeView.show(self: Self, state: State, canBack: boolean)
	self.current = state
	build(self, canBack)
	self.root.Visible = true
end

function RecipeView.turn(self: Self, delta: number)
	local state = self.current
	if state == nil then
		return
	end
	local group = state.groups[state.category]
	if group == nil then
		return
	end
	local pages = JeiData.pageCount(#group.entries, JeiLayout.perPage(group.category))
	local page = JeiData.turn(state.page, delta, pages)
	if page ~= state.page then
		state.page = page
		build(self)
	end
end

function RecipeView.selectCategory(self: Self, index: number)
	local state = self.current
	if state == nil or state.groups[index] == nil or index == state.category then
		return
	end
	state.category = index
	state.page = 1
	build(self)
end

--[[
	What each shown recipe still needs (Progression; nil: nothing): its output is greyed under a
	padlock while it needs something. `lockOf` answers JeiData.lockText for an entry.
]]
function RecipeView.setLocks(self: Self, lockOf: (entry: Entry) -> string?)
	self.lockOf = lockOf
	self:refreshLocks()
end

-- The locks again (the player's progression changed).
function RecipeView.refreshLocks(self: Self)
	local lockOf = self.lockOf
	for _, widget in self.widgets do
		local lock = if lockOf then lockOf(widget.entry) else nil
		widget.lock = lock
		local output, padlock = widget.output, widget.padlock
		if output then
			output.icon:setDimmed(lock ~= nil)
		end
		if padlock then
			padlock.Visible = lock ~= nil
		end
	end
end

-- What the recipe whose output is under `point` still needs (nil: nothing, or no output there).
function RecipeView.lockAt(self: Self, point: Vector2): string?
	if not self.root.Visible then
		return nil
	end
	for _, widget in self.widgets do
		local output = widget.output
		if widget.lock and output and Style.contains(output.button, point) then
			return widget.lock
		end
	end
	return nil
end

--[[
	Whether each shown crafting recipe gets a "+", and its state: `statusOf` answers
	JeiTransfer.status for an entry, or nil when no grid could take it (no "+" at all). It is called
	again whenever the page changes; call this again when the inventory changes.
]]
function RecipeView.setTransfer(self: Self, statusOf: (entry: Entry) -> JeiTransfer.Status?)
	self.statusOf = statusOf
	applyTransfer(self)
end

-- Asks the setTransfer function again for the shown recipes (the inventory changed).
function RecipeView.refreshTransfer(self: Self)
	applyTransfer(self)
end

-- Per frame: cycling ingredients, the animated gauges, the red over missing items while the
-- hovered "+" is greyed out.
function RecipeView.render(self: Self, now: number, point: Vector2?)
	local state = self.current
	if state == nil or not self.root.Visible then
		return
	end
	local focus = state.item
	local selected = GuiService.SelectedObject
	-- The white overlay on the slot under the pointer (or selected with a gamepad).
	local function light(slot: ItemIcon.Slot)
		local lit = slot.icon.item ~= nil
			and (selected == slot.button or (point ~= nil and Style.contains(slot.button, point)))
		if slot.hover.Visible ~= lit then
			slot.hover.Visible = lit
		end
	end
	for _, widget in self.widgets do
		for _, cell in widget.cells do
			cell.slot.icon:set(JeiData.shown(cell.items, now, focus), 1)
			light(cell.slot)
		end
		for _, fluid in widget.fluids do
			local lit = selected == fluid.slot.button or (point ~= nil and Style.contains(fluid.slot.button, point))
			if fluid.slot.hover.Visible ~= lit then
				fluid.slot.hover.Visible = lit
			end
		end
		local output = widget.output
		if output then
			light(output)
		end
		local phase = (now % widget.period) / widget.period
		local arrow = widget.arrow
		if arrow then
			setGauge(arrow, math.floor(phase * arrow.rect.w))
		end
		local flame = widget.flame
		if flame then
			setGauge(flame, flame.rect.h - math.floor(phase * flame.rect.h))
		end
		local status = widget.status
		local plus = widget.plus
		local hovered = plus ~= nil
			and plus.Visible
			and ((point ~= nil and Style.contains(plus, point)) or selected == plus)
		for _, cell in widget.cells do
			local red = hovered and status ~= nil and status.missing[cell.cell] == true
			if cell.missing.Visible ~= red then
				cell.missing.Visible = red
			end
		end
	end
end

-- The fluid stack under `point` (a refining or generator entry's), nil for none.
function RecipeView.fluidAt(self: Self, point: Vector2): JeiData.FluidStack?
	if not self.root.Visible then
		return nil
	end
	for _, widget in self.widgets do
		for _, fluid in widget.fluids do
			if Style.contains(fluid.slot.button, point) then
				return fluid.stack
			end
		end
	end
	return nil
end

--[[
	The item shown under `point` (a recipe's ingredient or result; a fluid stack: its bucket, which
	stands for it in lookups), and the cell's items.
]]
function RecipeView.itemAt(self: Self, point: Vector2): (number?, { number }?)
	if not self.root.Visible then
		return nil, nil
	end
	for _, widget in self.widgets do
		for _, fluid in widget.fluids do
			if Style.contains(fluid.slot.button, point) then
				return Fluids.bucketOf(fluid.stack.fluid), nil
			end
		end
		for _, cell in widget.cells do
			if cell.slot.icon.item and Style.contains(cell.slot.button, point) then
				return cell.slot.icon.item, cell.items
			end
		end
		local output = widget.output
		if output and output.icon.item and Style.contains(output.button, point) then
			return output.icon.item, nil
		end
	end
	return nil, nil
end

-- The item of a (gamepad) selected slot of the view (a fluid stack's: its bucket).
function RecipeView.itemOf(self: Self, object: GuiObject): number?
	local bucket = self.fluidButtons[object]
	if bucket then
		return bucket
	end
	local icon = self.byButton[object]
	return if icon then icon.item else nil
end

-- Tooltip lines for the view's other parts: the "+" button, the shapeless mark, the tabs.
function RecipeView.infoAt(self: Self, point: Vector2): { Line }?
	if not self.root.Visible then
		return nil
	end
	for _, widget in self.widgets do
		local plus, status = widget.plus, widget.status
		if plus and status and plus.Visible and Style.contains(plus, point) then
			local lines: { Line } = { { text = "Move Items", colour = Style.Colour.Text } }
			if status.ok then
				table.insert(lines, { text = "Shift: as many as possible", colour = Style.Colour.Gray })
			else
				table.insert(lines, { text = status.reason or JeiTransfer.FAILED, colour = Style.Colour.Red })
			end
			return lines
		end
		local mark = widget.shapeless
		if mark and Style.contains(mark, point) then
			return { { text = "Shapeless", colour = Style.Colour.Text } }
		end
	end
	for _, tab in self.tabs do
		local art = if tab.active.Visible then tab.activeArt elseif tab.inactive.Visible then tab.inactiveArt else nil
		if art and Style.contains(art, point) then
			return { { text = JeiData.TITLES[tab.category], colour = Style.Colour.Text } }
		end
	end
	return nil
end

-- Is `point` over the panel or one of its tabs?
function RecipeView.covers(self: Self, point: Vector2): boolean
	if not self.root.Visible then
		return false
	end
	if Style.contains(self.panel, point) then
		return true
	end
	for _, tab in self.tabs do
		if
			(tab.active.Visible and Style.contains(tab.activeArt, point))
			or (tab.inactive.Visible and Style.contains(tab.inactiveArt, point))
		then
			return true
		end
	end
	return false
end

-- Where gamepad selection starts: the first recipe's first ingredient, else its result.
function RecipeView.firstSelectable(self: Self): GuiObject?
	local widget = self.widgets[1]
	if widget == nil then
		return nil
	end
	for _, cell in widget.cells do
		if cell.items then
			return cell.slot.button
		end
	end
	local output = widget.output
	return if output then output.button else nil
end

-- Hides the view (the controller decides what comes next).
function RecipeView.hide(self: Self)
	self.root.Visible = false
	self.current = nil
	clearPage(self)
end

return RecipeView
