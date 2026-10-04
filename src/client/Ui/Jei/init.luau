--!strict
--[[
	JEI ("Just Enough Items", simplified) for the inventory screens: the item list beside them
	(Jei/JeiPanel), the recipe view (Jei/RecipeView) with its history, and the recipe transfer
	(Jei/JeiTransfer). Ui/Screens owns the input and calls in here; this module decides what JEI does
	with it:

	  item list    left click: the item's recipes, right click: its uses. In creative (JEI's cheat
	               mode) shift-left or middle click puts a full stack on the cursor, and clicking
	               the list with a carried stack deletes it (right click: one item), like the
	               creative grid
	  recipe view  the same clicks on its items navigate (recipes / uses of what was clicked);
	               Back (Backspace) returns to the previous view, the first one back to the
	               inventory; R / U over any item (Screens: list, view, slots, hotbar) look it up.
	               While it is open it takes the inventory panel's place (Screens hides that and
	               does no slot clicks)
	  "+"          on a crafting recipe while a crafting grid is shown (the inventory screen: window
	               0's 2 x 2 or a crafting table's 3 x 3): JeiTransfer.plan, sent action by action
	               through the host (ClientInventory.apply: predicted, then checked by the server),
	               then back to the inventory. Shift: as many sets as the inventory holds. It is lit
	               only when JeiTransfer.status finds a plan (checked again on inventory changes)

	Lookups that find nothing do nothing, like JEI.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Types = require(Shared.Inventory.Types)

local Style = require(script.Parent.Style)

local JeiData = require(script.JeiData)
local JeiLayout = require(script.JeiLayout)
local JeiPanel = require(script.JeiPanel)
local JeiTransfer = require(script.JeiTransfer)
local RecipeView = require(script.RecipeView)

export type Line = RecipeView.Line

export type Host = {
	-- The (predicted) window and game mode, and a way to predict and send an action.
	window: () -> Types.Window,
	creative: () -> boolean,
	apply: (action: Types.Action) -> (),
	-- Does the screen under the recipe view show the window's crafting grid (the inventory screen)?
	gridShown: () -> boolean,
}

-- Where the list and the view go (Screens.layout): screen pixels and GUI scales.
export type Placement = {
	viewportX: number,
	-- Usable height: below Roblox's top bar, above the creative hotbar.
	top: number,
	bottom: number,
	-- Right edge of the inventory panel.
	guiRight: number,
	scale: number,
	viewScale: number,
}

export type Jei = {
	list: JeiPanel.JeiPanel,
	view: RecipeView.RecipeView,
	-- Set by Screens: called when the recipe view opens (true) or closes (false).
	onViewChanged: (open: boolean) -> (),
	setVisible: (self: Jei, visible: boolean) -> (),
	place: (self: Jei, placement: Placement) -> (),
	viewOpen: (self: Jei) -> boolean,
	show: (self: Jei, item: number?, mode: JeiData.Mode) -> boolean,
	back: (self: Jei) -> (),
	closeView: (self: Jei) -> (),
	inventoryChanged: (self: Jei) -> (),
	covers: (self: Jei, point: Vector2) -> boolean,
	itemAt: (self: Jei, point: Vector2) -> (number?, boolean),
	itemOf: (self: Jei, object: GuiObject) -> (number?, boolean),
	press: (self: Jei, point: Vector2, button: number, shift: boolean) -> boolean,
	activate: (self: Jei, item: number, button: number, shift: boolean, inList: boolean) -> (),
	wheel: (self: Jei, point: Vector2, delta: number) -> boolean,
	render: (self: Jei, now: number, point: Vector2?) -> (),
	tooltipAt: (self: Jei, point: Vector2) -> (number?, { Line }?),
	firstSelectable: (self: Jei) -> GuiObject?,
	typing: (self: Jei) -> boolean,
}

type Self = Jei & {
	host: Host,
	viewScale: UIScale,
	history: { RecipeView.State },
	transferDirty: boolean,
}

local Jei = {}
Jei.__index = Jei

-- Mouse buttons (SlotClicks.Button).
local LEFT, RIGHT, MIDDLE = 0, 1, 2
-- Views Back can return to (the oldest are forgotten).
local MAX_HISTORY = 64

function Jei.new(parent: Instance, host: Host): Jei
	local list = JeiPanel.new(parent)
	local view = RecipeView.new(parent)
	local viewScale = Instance.new("UIScale")
	viewScale.Parent = view.root
	local self = (
		setmetatable({
			list = list,
			view = view,
			onViewChanged = function() end,
			host = host,
			viewScale = viewScale,
			history = {},
			transferDirty = true,
		}, Jei) :: any
	) :: Self

	view.onBack = function()
		self:back()
	end
	view.onClose = function()
		self:closeView()
	end
	view.onTransfer = function(entry: JeiData.Entry, all: boolean)
		local recipe = entry.recipe
		if recipe == nil or not host.gridShown() then
			return
		end
		local actions = JeiTransfer.plan(host.window(), recipe, all, host.creative())
		if actions == nil then
			return
		end
		for _, action in actions do
			host.apply(action)
		end
		-- Back to the grid, now holding the recipe (JEI closes its recipe screen too).
		self:closeView()
	end
	-- The "+" buttons: only while a crafting grid is shown.
	view:setTransfer(function(entry: JeiData.Entry): JeiTransfer.Status?
		local recipe = entry.recipe
		if recipe == nil or not host.gridShown() then
			return nil
		end
		local window = host.window()
		if JeiTransfer.gridWidth(window) == 0 then
			return nil
		end
		return JeiTransfer.status(window, recipe, host.creative())
	end)
	return self
end

-- Shows the list while a screen is open; closing the screen closes the view too.
function Jei.setVisible(self: Self, visible: boolean)
	self.list:setVisible(visible)
	if not visible then
		self:closeView()
	end
end

function Jei.place(self: Self, placement: Placement)
	local layout =
		JeiLayout.list(placement.viewportX, placement.top, placement.bottom, placement.guiRight, placement.scale)
	self.list:setLayout(layout)
	if self.viewScale.Scale ~= placement.viewScale then
		self.viewScale.Scale = placement.viewScale
	end
end

function Jei.viewOpen(self: Self): boolean
	return self.view:state() ~= nil
end

--[[
	Opens the recipe view on an item's recipes or uses (the current view goes into the history).
	Returns false, and changes nothing, when there is nothing to show.
]]
function Jei.show(self: Self, item: number?, mode: JeiData.Mode): boolean
	if item == nil or not Items.isValid(item) then
		return false
	end
	local groups = JeiData.lookup(mode, item)
	if #groups == 0 then
		return false
	end
	local current = self.view:state()
	if current then
		if current.item == item and current.mode == mode then
			return true
		end
		table.insert(self.history, current)
		if #self.history > MAX_HISTORY then
			table.remove(self.history, 1)
		end
	end
	self.transferDirty = true
	self.view:show({ item = item, mode = mode, groups = groups, category = 1, page = 1 }, #self.history > 0)
	if current == nil then
		self.onViewChanged(true)
	end
	return true
end

-- Back to the previous view; from the first one back to the inventory.
function Jei.back(self: Self)
	local previous = table.remove(self.history)
	if previous then
		self.transferDirty = true
		self.view:show(previous, #self.history > 0)
	else
		self:closeView()
	end
end

function Jei.closeView(self: Self)
	table.clear(self.history)
	if self.view:state() ~= nil then
		self.view:hide()
		self.onViewChanged(false)
	end
end

-- The inventory changed: the "+" buttons are checked again.
function Jei.inventoryChanged(self: Self)
	self.transferDirty = true
end

-- Is `point` over JEI (the list, or the open view)? Clicks there are never slot clicks.
function Jei.covers(self: Self, point: Vector2): boolean
	return self.list:covers(point) or self.view:covers(point)
end

-- The item under `point` in the view or the list, and whether it is the list's.
function Jei.itemAt(self: Self, point: Vector2): (number?, boolean)
	local item = self.view:itemAt(point)
	if item then
		return item, false
	end
	local listed = self.list:itemAt(point)
	return listed, listed ~= nil
end

-- The item of a (gamepad) selected JEI cell, and whether it is the list's.
function Jei.itemOf(self: Self, object: GuiObject): (number?, boolean)
	local listed = self.list:itemOf(object)
	if listed then
		return listed, true
	end
	return self.view:itemOf(object), false
end

--[[
	A click on `item` (in the list: `inList`, or the view) with mouse button `button`: recipes
	(left), uses (right); in creative the cheat mode clicks (see the header). Only the list deletes
	a carried stack: clicks in the view always navigate.
]]
function Jei.activate(self: Self, item: number, button: number, shift: boolean, inList: boolean)
	local host = self.host
	if host.creative() then
		local window = host.window()
		local carried = window.inventory.cursor
		if inList and carried and carried.count >= 1 then
			-- Dropping a stack on JEI deletes it (one item with the right button).
			local count = if button == RIGHT then carried.count - 1 elseif button == LEFT then 0 else nil
			if count then
				host.apply({
					kind = "creative",
					window = window.id,
					slot = Types.CURSOR,
					item = carried.item,
					count = count,
				})
			end
			return
		end
		if (carried == nil or carried.count < 1) and (button == MIDDLE or (button == LEFT and shift)) then
			host.apply({
				kind = "creative",
				window = window.id,
				slot = Types.CURSOR,
				item = item,
				count = Items.maxStack(item),
			})
			return
		end
	end
	if button == LEFT then
		self:show(item, "recipes")
	elseif button == RIGHT then
		self:show(item, "uses")
	end
end

--[[
	A mouse press at `point`: true when JEI took it (an item, or anything over the list or the
	view; its buttons and the search field handle themselves).
]]
function Jei.press(self: Self, point: Vector2, button: number, shift: boolean): boolean
	local item, inList = self:itemAt(point)
	if item then
		self:activate(item, button, shift, inList)
		return true
	end
	return self:covers(point)
end

-- The mouse wheel over the view or the list turns its pages (down: the next page).
function Jei.wheel(self: Self, point: Vector2, delta: number): boolean
	if delta == 0 then
		return false
	end
	local step = if delta < 0 then 1 else -1
	if self.view:covers(point) then
		self.view:turn(step)
		return true
	elseif self.list:covers(point) then
		self.list:turn(step)
		return true
	end
	return false
end

function Jei.render(self: Self, now: number, point: Vector2?)
	self.list:render(if point then self.list:itemAt(point) else nil)
	if self:viewOpen() then
		if self.transferDirty then
			self.transferDirty = false
			self.view:refreshTransfer()
		end
		self.view:render(now, point)
	end
end

--[[
	The tooltip at `point`: an item (the screens' item tooltip) with extra lines (a tag ingredient
	says which tag), or lines of their own (the view's "+", shapeless mark and tabs).
]]
function Jei.tooltipAt(self: Self, point: Vector2): (number?, { Line }?)
	local item, items = self.view:itemAt(point)
	if item then
		local tag = JeiData.tagOf(items)
		if tag then
			return item, { { text = `Any {tag}`, colour = Style.Colour.Gray } }
		end
		return item, nil
	end
	local info = self.view:infoAt(point)
	if info then
		return nil, info
	end
	return self.list:itemAt(point), nil
end

-- Where gamepad selection goes when the view opens.
function Jei.firstSelectable(self: Self): GuiObject?
	if self:viewOpen() then
		return self.view:firstSelectable()
	end
	return self.list:firstSelectable()
end

-- Is the search field focused (keys are text)?
function Jei.typing(self: Self): boolean
	return self.list.search:IsFocused()
end

return Jei
