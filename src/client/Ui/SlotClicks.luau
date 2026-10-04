--!strict
--[[
	What the mouse does on an inventory screen: the screen side of Minecraft 1.20.1's container
	screens (AbstractContainerScreen.mouseClicked / mouseDragged / mouseReleased / keyPressed) and
	the creative item grid (CreativeModeInventoryScreen.slotClicked), turned into inventory actions
	(Inventory/Types Action) for the host to predict and send. Pure: no Roblox APIs, so the tests
	drive it with plain numbers.

	Targets are what is under the pointer:

	    { kind = "slot", index }   a window slot
	    { kind = "grid", item }    an item in the creative grid (creative only)
	    { kind = "outside" }       outside every panel: clicks there throw the carried stack
	    nil                        a panel, but no slot: nothing happens

	Mouse buttons: 0 left, 1 right, 2 middle.

	  * Press with an empty cursor: the click happens at once (left / right Pickup, shift Quick
	    move, middle Clone) and the release is ignored.
	  * Press with a carried stack: a drag starts. Moving over slots adds those that can take the
	    item (while the stack has more items than slots, or always for a middle drag). The release
	    spreads the stack over them (drag Split / One / Clone); with no slot it is a plain click on
	    whatever is under the pointer then (Pickup, Quick move with shift, or a throw outside).
	  * A second left press on the same slot within 250 ms is a double click: on release it
	    gathers the item onto the cursor (Pickup all), or with shift quick moves every stack of
	    that item from the same part of the window (the container or the player's slots).
	  * Number keys over a slot swap it with that hotbar slot, Q throws one of it (Ctrl+Q all), as
	    long as the cursor is empty.
	  * The creative grid gives full stacks: a click puts one on the cursor, shift a full stack in
	    the selected hotbar slot, a number key one in that hotbar slot. Clicking it with a carried
	    stack deletes the stack (right click: one item).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

type Window = Types.Window
type Action = Types.Action
type Stack = Types.Stack

export type Target = { kind: "slot", index: number } | { kind: "grid", item: number } | { kind: "outside" }

export type Host = {
	-- The (predicted) window the screen shows.
	window: () -> Window,
	creative: () -> boolean,
	-- Predicts and sends an action; `window()` reflects it right after.
	apply: (action: Action) -> (),
}

export type SlotClicks = {
	press: (self: SlotClicks, target: Target?, button: number, shift: boolean, now: number) -> (),
	move: (self: SlotClicks, target: Target?) -> (),
	release: (self: SlotClicks, target: Target?, button: number, shift: boolean, now: number) -> (),
	click: (self: SlotClicks, target: Target?, button: number, shift: boolean, now: number) -> (),
	hotbarKey: (self: SlotClicks, target: Target?, slot: number) -> (),
	throwKey: (self: SlotClicks, target: Target?, all: boolean) -> (),
	cancel: (self: SlotClicks) -> (),
	dragging: (self: SlotClicks) -> (number?, { number }),
	busy: (self: SlotClicks) -> boolean,
}

type Self = SlotClicks & {
	host: Host,
	lastTarget: Target?,
	lastTime: number,
	lastButton: number,
	doubleClick: boolean,
	skipNextRelease: boolean,
	quickCrafting: boolean,
	quickButton: number,
	quickType: number,
	quickSlots: { number },
	-- Item of the last shift click (for shift + double click).
	lastQuickMoved: number?,
}

local SlotClicks = {}
SlotClicks.__index = SlotClicks

SlotClicks.Button = { Left = 0, Right = 1, Middle = 2 }
-- Minecraft's double click window (seconds).
SlotClicks.DOUBLE_CLICK = 0.25

local LEFT, RIGHT, MIDDLE = 0, 1, 2
local Click = Menu.ClickType

local function sameTarget(a: Target?, b: Target?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if a.kind == "slot" and b.kind == "slot" then
		return a.index == b.index
	elseif a.kind == "grid" and b.kind == "grid" then
		return a.item == b.item
	end
	return a.kind == b.kind
end

local function cursorOf(window: Window): Stack?
	local cursor = window.inventory.cursor
	if cursor == nil or cursor.count < 1 then
		return nil
	end
	return cursor
end

function SlotClicks.new(host: Host): SlotClicks
	local self = {
		host = host,
		lastTarget = nil,
		lastTime = -math.huge,
		lastButton = -1,
		doubleClick = false,
		skipNextRelease = false,
		quickCrafting = false,
		quickButton = -1,
		quickType = 0,
		quickSlots = {},
		lastQuickMoved = nil,
	}
	return (setmetatable(self, SlotClicks) :: any) :: SlotClicks
end

local function click(self: Self, index: number, clickType: number, button: number)
	self.host.apply({
		kind = "click",
		window = self.host.window().id,
		slot = index,
		clickType = clickType,
		button = button,
	})
end

local function creative(self: Self, slot: number, item: number, count: number)
	self.host.apply({ kind = "creative", window = self.host.window().id, slot = slot, item = item, count = count })
end

-- Window slot of hotbar slot 1..9.
local function hotbarIndex(window: Window, slot: number): number
	return Menu.windowIndex(window, "inventory", slot) :: number
end

-- The creative grid with an empty cursor: full stacks.
local function gridTake(self: Self, item: number, shift: boolean)
	if not self.host.creative() or not Items.isValid(item) then
		return
	end
	local window = self.host.window()
	if shift then
		creative(self, hotbarIndex(window, window.inventory.selected), item, Items.maxStack(item))
	else
		creative(self, Types.CURSOR, item, Items.maxStack(item))
	end
end

-- The creative grid clicked with a carried stack: deletes it (right click: one item).
local function gridDrop(self: Self, carried: Stack, button: number)
	if not self.host.creative() then
		return
	end
	if button == LEFT then
		creative(self, Types.CURSOR, carried.item, 0)
	elseif button == RIGHT then
		creative(self, Types.CURSOR, carried.item, carried.count - 1)
	end
end

function SlotClicks.press(self: Self, target: Target?, button: number, shift: boolean, now: number)
	local window = self.host.window()
	self.doubleClick = sameTarget(self.lastTarget, target)
		and now - self.lastTime < SlotClicks.DOUBLE_CLICK
		and self.lastButton == button
	self.skipNextRelease = false
	if target ~= nil and not self.quickCrafting then
		local carried = cursorOf(window)
		if carried == nil then
			if target.kind == "grid" then
				gridTake(self, target.item, shift and button ~= MIDDLE)
			elseif target.kind == "slot" then
				if button == MIDDLE then
					if self.host.creative() then
						click(self, target.index, Click.Clone, MIDDLE)
					end
				elseif shift then
					local stack = Menu.get(window, target.index)
					self.lastQuickMoved = if stack then stack.item else nil
					click(self, target.index, Click.QuickMove, button)
				else
					click(self, target.index, Click.Pickup, button)
				end
			end
			-- (Outside with nothing carried: Minecraft's THROW on no slot, which does nothing.)
			self.skipNextRelease = true
		else
			self.quickCrafting = true
			self.quickButton = button
			self.quickType = button
			table.clear(self.quickSlots)
		end
	end
	self.lastTarget = target
	self.lastTime = now
	self.lastButton = button
end

-- The pointer moved (with a button held) over `target`: a drag picks up the slots it crosses.
function SlotClicks.move(self: Self, target: Target?)
	if not self.quickCrafting or target == nil or target.kind ~= "slot" then
		return
	end
	local window = self.host.window()
	local carried = cursorOf(window)
	if carried == nil then
		return
	end
	if self.quickType == MIDDLE and not self.host.creative() then
		return
	end
	local index = target.index
	if table.find(self.quickSlots, index) or #self.quickSlots >= Types.MAX_DRAG then
		return
	end
	if carried.count <= #self.quickSlots and self.quickType ~= MIDDLE then
		return
	end
	-- canItemQuickReplace (ignoring the carried count) and mayPlace.
	local current = Menu.get(window, index)
	if current and (current.item ~= carried.item or current.count > Items.maxStack(carried.item)) then
		return
	end
	if not Menu.mayPlace(window, index, carried.item) then
		return
	end
	table.insert(self.quickSlots, index)
end

function SlotClicks.release(self: Self, target: Target?, button: number, shift: boolean, _now: number)
	local window = self.host.window()
	if self.doubleClick and target ~= nil and target.kind == "slot" and button == LEFT then
		if shift then
			local item = self.lastQuickMoved
			if item then
				local inContainer = Menu.locate(window, target.index) == "container"
				for index = 0, Menu.size(window) - 1 do
					local current = Menu.get(self.host.window(), index)
					if
						current
						and current.item == item
						and (Menu.locate(window, index) == "container") == inContainer
					then
						click(self, index, Click.QuickMove, LEFT)
					end
				end
			end
		else
			click(self, target.index, Click.PickupAll, LEFT)
		end
		self.doubleClick = false
		self.lastTime = -math.huge
	else
		if self.quickCrafting and self.quickButton ~= button then
			-- Another button let go during a drag: it is cancelled.
			self.quickCrafting = false
			table.clear(self.quickSlots)
			self.skipNextRelease = true
			return
		end
		if self.skipNextRelease then
			self.skipNextRelease = false
			return
		end
		local carried = cursorOf(window)
		if self.quickCrafting and #self.quickSlots > 0 then
			self.host.apply({
				kind = "drag",
				window = window.id,
				mode = self.quickType,
				slots = table.clone(self.quickSlots),
			})
		elseif carried and button ~= MIDDLE and target ~= nil then
			if target.kind == "grid" then
				gridDrop(self, carried, button)
			elseif target.kind == "slot" then
				if shift then
					local stack = Menu.get(window, target.index)
					self.lastQuickMoved = if stack then stack.item else nil
					click(self, target.index, Click.QuickMove, button)
				else
					click(self, target.index, Click.Pickup, button)
				end
			else
				click(self, Types.OUTSIDE, Click.Pickup, button)
			end
		end
	end
	if cursorOf(self.host.window()) == nil then
		self.lastTime = -math.huge
	end
	self.quickCrafting = false
	table.clear(self.quickSlots)
end

-- A press and release in one go (gamepad buttons, taps).
function SlotClicks.click(self: Self, target: Target?, button: number, shift: boolean, now: number)
	self:press(target, button, shift, now)
	self:release(target, button, shift, now)
end

-- Number key `slot` (1..9) over `target`: swap with that hotbar slot (empty cursor only).
function SlotClicks.hotbarKey(self: Self, target: Target?, slot: number)
	local window = self.host.window()
	if target == nil or cursorOf(window) ~= nil or slot < 1 or slot > Types.HOTBAR_SIZE then
		return
	end
	if target.kind == "slot" then
		click(self, target.index, Click.Swap, slot - 1)
	elseif target.kind == "grid" and self.host.creative() and Items.isValid(target.item) then
		creative(self, hotbarIndex(window, slot), target.item, Items.maxStack(target.item))
	end
end

-- Q over `target` (Ctrl+Q: `all`): throws from the slot (empty cursor only).
function SlotClicks.throwKey(self: Self, target: Target?, all: boolean)
	local window = self.host.window()
	if target == nil or cursorOf(window) ~= nil then
		return
	end
	if target.kind == "slot" then
		if Menu.get(window, target.index) then
			click(self, target.index, Click.Throw, if all then 1 else 0)
		end
	elseif target.kind == "grid" and self.host.creative() and Items.isValid(target.item) then
		-- A creative grid item is thrown through the cursor: put it there, throw the cursor.
		creative(self, Types.CURSOR, target.item, if all then Items.maxStack(target.item) else 1)
		click(self, Types.OUTSIDE, Click.Pickup, LEFT)
	end
end

-- Forgets a drag in progress and the double click state (the screen closed or changed).
function SlotClicks.cancel(self: Self)
	self.quickCrafting = false
	table.clear(self.quickSlots)
	self.skipNextRelease = false
	self.doubleClick = false
	self.lastTarget = nil
	self.lastTime = -math.huge
end

-- The drag in progress: its mode and slots (nil, {} when not dragging).
function SlotClicks.dragging(self: Self): (number?, { number })
	if self.quickCrafting and #self.quickSlots > 0 then
		return self.quickType, self.quickSlots
	end
	return nil, {}
end

-- Is a button down in a way that matters (a drag started)?
function SlotClicks.busy(self: Self): boolean
	return self.quickCrafting
end

return SlotClicks
