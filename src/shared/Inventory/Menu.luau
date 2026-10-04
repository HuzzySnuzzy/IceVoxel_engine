--!strict
--[[
	Inventory logic: Minecraft 1.20.1's container menus (AbstractContainerMenu.doClick,
	InventoryMenu / ChestMenu.quickMoveStack, moveItemStackTo, Slot.safeInsert / tryRemove and
	Inventory.add) ported onto the window layout of Inventory/Types:

	    [0, n)            container slots (n = 0 without a container)
	    [n, n + 4)        armor: head, chest, legs, feet (only armor of that slot, one item each)
	    [n + 4, n + 31)   inventory slots 10..36
	    [n + 31, n + 40)  hotbar, inventory slots 1..9

	The server applies every player action with `Menu.apply` (it is the authority) and the client
	predicts by replaying its unacknowledged actions on a copy of the last snapshot, so everything
	here is pure and deterministic: no Roblox APIs, no randomness, numeric loops only.

	`apply` mutates the window in place and returns the stacks thrown out of it (THROW clicks,
	clicks outside, `drop`, close leftovers), which the server turns into item entities. Actions
	that break a rule (wrong window id, slot out of range, unknown item, count above the max stack,
	creative-only action in survival, bad drag mode...) change nothing and return {}. It never
	errors, whatever a client sends.

	Stacks are treated as values: a changed slot gets a new table, so no table is ever shared by
	two slots and a caller holding an old stack never sees it change.
]]

local Items = require(script.Parent.Parent.Items)
local Types = require(script.Parent.Types)

type Stack = Types.Stack
type Window = Types.Window
type Inventory = Types.Inventory
type Container = Types.Container
type Action = Types.Action

local Menu = {}

-- Minecraft's ClickType, without QUICK_CRAFT (that is the `drag` action, sent in one piece).
Menu.ClickType = { Pickup = 0, QuickMove = 1, Swap = 2, Clone = 3, Throw = 4, PickupAll = 5 }
-- Quick craft (drag) types: split evenly, one each, a full stack each (creative).
Menu.DragMode = { Split = 0, One = 1, Clone = 2 }

local PICKUP, QUICK_MOVE, SWAP, CLONE, THROW, PICKUP_ALL = 0, 1, 2, 3, 4, 5
local SPLIT, ONE, CLONE_DRAG = 0, 1, 2

local OUTSIDE = Types.OUTSIDE
local CURSOR = Types.CURSOR
local ARMOR = Types.ARMOR_SIZE
local HOTBAR = Types.HOTBAR_SIZE
local INVENTORY = Types.INVENTORY_SIZE
-- Window offsets past the container: armor, then inventory 10..36, then the hotbar.
local MAIN_START = ARMOR -- 4
local HOTBAR_START = ARMOR + INVENTORY - HOTBAR -- 31
local PLAYER_END = Types.PLAYER_SLOTS -- 40

--[[ Helpers ]]

local function isInt(value: any): boolean
	-- NaN fails (NaN ~= NaN); infinities pass but every caller checks a range too.
	return type(value) == "number" and value == math.floor(value)
end

-- A new stack, or nil for a count below 1 (Minecraft's empty ItemStack).
local function make(item: number, count: number): Stack?
	if count < 1 then
		return nil
	end
	return { item = item, count = count }
end

local function copy(stack: Stack?): Stack?
	if stack == nil or stack.count < 1 then
		return nil
	end
	return { item = stack.item, count = stack.count }
end

local function containerSize(window: Window): number
	local container = window.container
	return if container then container.size else 0
end

-- Minecraft's Slot.getMaxStackSize() (without an item): 1 for armor, else the container's 64.
local function slotLimit(window: Window, index: number): number
	local offset = index - containerSize(window)
	return if offset >= 0 and offset < ARMOR then 1 else Items.MAX_STACK
end

--[[ Slots ]]

-- Number of window slots.
function Menu.size(window: Window): number
	return Types.windowSize(containerSize(window))
end

--[[
	Which store a window slot lives in and its index there: "container" (1..n), "armor" (1..4) or
	"inventory" (1..36, 1-9 the hotbar). nil, 0 for anything else (OUTSIDE, out of range).
]]
function Menu.locate(window: Window, index: number): (string?, number)
	if not isInt(index) or index < 0 then
		return nil, 0
	end
	local n = containerSize(window)
	if index < n then
		return "container", index + 1
	end
	local offset = index - n
	if offset < MAIN_START then
		return "armor", offset + 1
	elseif offset < HOTBAR_START then
		return "inventory", offset - MAIN_START + HOTBAR + 1
	elseif offset < PLAYER_END then
		return "inventory", offset - HOTBAR_START + 1
	end
	return nil, 0
end

-- Window slot of a store index (the inverse of locate), or nil.
function Menu.windowIndex(window: Window, store: string, index: number): number?
	if not isInt(index) then
		return nil
	end
	local n = containerSize(window)
	if store == "container" and index >= 1 and index <= n then
		return index - 1
	elseif store == "armor" and index >= 1 and index <= ARMOR then
		return n + index - 1
	elseif store == "inventory" and index >= 1 and index <= HOTBAR then
		return n + HOTBAR_START + index - 1
	elseif store == "inventory" and index > HOTBAR and index <= INVENTORY then
		return n + MAIN_START + index - HOTBAR - 1
	end
	return nil
end

-- The stack in a window slot (nil when empty or not a slot).
function Menu.get(window: Window, index: number): Stack?
	local store, i = Menu.locate(window, index)
	local stack: Stack? = nil
	if store == "container" then
		stack = (window.container :: Container).slots[i]
	elseif store == "armor" then
		stack = window.inventory.armor[i]
	elseif store == "inventory" then
		stack = window.inventory.slots[i]
	end
	if stack == nil or stack.count < 1 then
		return nil
	end
	return stack
end

-- Puts `stack` (as is, not copied; nil or a count below 1 empties it) in a window slot.
function Menu.set(window: Window, index: number, stack: Stack?)
	if stack ~= nil and stack.count < 1 then
		stack = nil
	end
	local store, i = Menu.locate(window, index)
	if store == "container" then
		(window.container :: Container).slots[i] = stack
	elseif store == "armor" then
		window.inventory.armor[i] = stack
	elseif store == "inventory" then
		window.inventory.slots[i] = stack
	end
end

-- Slot.mayPlace: armor slots take only armor of their slot, other slots any known item.
function Menu.mayPlace(window: Window, index: number, item: number): boolean
	if not Items.isValid(item) then
		return false
	end
	local store, i = Menu.locate(window, index)
	if store == "armor" then
		return Items.armorSlot(item) == i
	end
	return store ~= nil
end

-- Slot.getMaxStackSize(stack): the item's max stack, at most 1 in armor slots (0 if not a slot).
function Menu.maxStackFor(window: Window, index: number, item: number): number
	if Menu.locate(window, index) == nil then
		return 0
	end
	return math.min(Items.maxStack(item), slotLimit(window, index))
end

local get, set, mayPlace, maxStackFor = Menu.get, Menu.set, Menu.mayPlace, Menu.maxStackFor

local function cursorOf(window: Window): Stack?
	local cursor = window.inventory.cursor
	if cursor == nil or cursor.count < 1 then
		return nil
	end
	return cursor
end

--[[ Slot primitives (Minecraft's Slot) ]]

--[[
	Slot.safeInsert: moves up to `n` of `carried` into the slot (if it may go there and the slot is
	empty or holds the same item) and returns what is left of `carried`.
]]
local function safeInsert(window: Window, index: number, carried: Stack, n: number): Stack?
	if not mayPlace(window, index, carried.item) then
		return carried
	end
	local current = get(window, index)
	local have = if current then current.count else 0
	local moved = math.min(n, carried.count, maxStackFor(window, index, carried.item) - have)
	if current == nil then
		set(window, index, make(carried.item, moved))
	elseif current.item == carried.item then
		moved = math.max(moved, 0)
		set(window, index, make(current.item, have + moved))
	else
		return carried
	end
	return make(carried.item, carried.count - moved)
end

--[[
	Slot.tryRemove: takes up to min(n, limit) items out of the slot. A slot whose item could not be
	put back (allowModification false) only gives its whole stack. Returns the taken stack or nil.
]]
local function tryRemove(window: Window, index: number, n: number, limit: number): Stack?
	local current = get(window, index)
	if current == nil then
		return nil
	end
	if not mayPlace(window, index, current.item) and limit < current.count then
		return nil
	end
	local taken = math.min(n, limit, current.count)
	if taken < 1 then
		return nil
	end
	set(window, index, make(current.item, current.count - taken))
	return make(current.item, taken)
end

--[[ Adding to the inventory (Minecraft's Inventory.add) ]]

--[[
	Puts `stack` into the inventory (it is not changed) and returns what did not fit (nil = all of
	it fitted). Each round picks, like Inventory.getSlotWithRemainingSpace / getFreeSlot:
	  1. the selected hotbar slot, if it holds the same item and has room;
	  2. the first slot (1..36, so the hotbar first) with the same item and room;
	  3. the first empty slot (1..36).
	Items that don't stack (max 1) only go into empty slots.
]]
function Menu.add(inventory: Inventory, stack: Stack): Stack?
	if stack == nil or not isInt(stack.count) or stack.count < 1 then
		return nil
	end
	local item = stack.item
	if not Items.isValid(item) then
		return copy(stack)
	end
	local slots = inventory.slots
	local max = math.min(Items.maxStack(item), Items.MAX_STACK)
	local function hasRoom(slot: number): boolean
		local current = slots[slot]
		return current ~= nil and current.count >= 1 and current.item == item and max > 1 and current.count < max
	end
	local count = stack.count
	while count > 0 do
		local target: number? = nil
		local selected = inventory.selected
		if isInt(selected) and selected >= 1 and selected <= HOTBAR and hasRoom(selected) then
			target = selected
		else
			for slot = 1, INVENTORY do
				if hasRoom(slot) then
					target = slot
					break
				end
			end
		end
		if target == nil then
			for slot = 1, INVENTORY do
				local current = slots[slot]
				if current == nil or current.count < 1 then
					target = slot
					break
				end
			end
		end
		if target == nil then
			break
		end
		local current = slots[target]
		local have = if current and current.count >= 1 then current.count else 0
		local put = math.min(count, max - have)
		if put < 1 then
			break
		end
		slots[target] = { item = item, count = have + put }
		count -= put
	end
	return make(item, count)
end

--[[ Clicks ]]

-- Clicking outside the window with a stack: throw all of it (left) or one (right).
local function throwCursor(window: Window, button: number): { Stack }
	local carried = cursorOf(window)
	if carried == nil then
		return {}
	end
	if button == 0 then
		window.inventory.cursor = nil
		return { { item = carried.item, count = carried.count } }
	end
	window.inventory.cursor = make(carried.item, carried.count - 1)
	return { { item = carried.item, count = 1 } }
end

-- PICKUP (left / right click) on a window slot.
local function pickup(window: Window, index: number, button: number)
	local inventory = window.inventory
	local carried = cursorOf(window)
	local current = get(window, index)
	if current == nil then
		if carried then
			inventory.cursor = safeInsert(window, index, carried, if button == 0 then carried.count else 1)
		end
	elseif carried == nil then
		-- Take all (left) or half, rounded up (right).
		local n = if button == 0 then current.count else (current.count + 1) // 2
		local taken = tryRemove(window, index, n, math.huge)
		if taken then
			inventory.cursor = taken
		end
	elseif mayPlace(window, index, carried.item) then
		if current.item == carried.item then
			inventory.cursor = safeInsert(window, index, carried, if button == 0 then carried.count else 1)
		elseif carried.count <= maxStackFor(window, index, carried.item) then
			-- Different items: swap them.
			inventory.cursor = current
			set(window, index, carried)
		end
	elseif current.item == carried.item then
		-- The carried stack may not go here, but the slot's (same) items may join it.
		local taken = tryRemove(window, index, current.count, Items.maxStack(carried.item) - carried.count)
		if taken then
			inventory.cursor = make(carried.item, carried.count + taken.count)
		end
	end
end

--[[
	moveItemStackTo: moves `stack` into window slots [from, to) (backwards when `reverse`): first
	merging into stacks of the same item, then into the FIRST suitable empty slot only. Returns
	what is left (nil = everything moved) and whether anything moved.
]]
local function moveItemStackTo(
	window: Window,
	stack: Stack,
	from: number,
	to: number,
	reverse: boolean
): (Stack?, boolean)
	local item = stack.item
	local count = stack.count
	local max = Items.maxStack(item)
	local step = if reverse then -1 else 1
	local first = if reverse then to - 1 else from
	local moved = false
	if max > 1 then
		local index = first
		while count > 0 and index >= from and index < to do
			local current = get(window, index)
			if current and current.item == item then
				local total = current.count + count
				if total <= max then
					count = 0
					set(window, index, make(item, total))
					moved = true
				elseif current.count < max then
					count -= max - current.count
					set(window, index, make(item, max))
					moved = true
				end
			end
			index += step
		end
	end
	if count > 0 then
		local index = first
		while index >= from and index < to do
			if get(window, index) == nil and mayPlace(window, index, item) then
				local put = math.min(count, slotLimit(window, index))
				set(window, index, make(item, put))
				count -= put
				moved = true
				break
			end
			index += step
		end
	end
	return make(item, count), moved
end

--[[
	quickMoveStack (one round of a shift click). Returns the slot's stack as it was before the move,
	or nil when nothing moved, like Minecraft (the caller repeats while it keeps moving).
	  With a container (ChestMenu): container -> inventory and hotbar, backwards (hotbar right end
	  first); anything else -> the container.
	  Without (InventoryMenu): armor -> inventory then hotbar; armor items -> their armor slot when
	  it is empty; inventory 10..36 -> hotbar; hotbar -> inventory 10..36.
]]
local function quickMoveStack(window: Window, index: number): Stack?
	local current = get(window, index)
	if current == nil then
		return nil
	end
	local n = containerSize(window)
	local left: Stack?, moved: boolean
	if n > 0 then
		if index < n then
			left, moved = moveItemStackTo(window, current, n + MAIN_START, n + PLAYER_END, true)
		else
			left, moved = moveItemStackTo(window, current, 0, n, false)
		end
		if not moved then
			return nil
		end
		set(window, index, left)
		return current
	end
	local armorSlot = Items.armorSlot(current.item)
	if index < MAIN_START then
		left, moved = moveItemStackTo(window, current, MAIN_START, PLAYER_END, false)
	elseif armorSlot and get(window, armorSlot - 1) == nil then
		left, moved = moveItemStackTo(window, current, armorSlot - 1, armorSlot, false)
	elseif index < HOTBAR_START then
		left, moved = moveItemStackTo(window, current, HOTBAR_START, PLAYER_END, false)
	else
		left, moved = moveItemStackTo(window, current, MAIN_START, HOTBAR_START, false)
	end
	if not moved then
		return nil
	end
	set(window, index, left)
	if (if left then left.count else 0) == current.count then
		return nil
	end
	return current
end

local function quickMove(window: Window, index: number)
	local result = quickMoveStack(window, index)
	-- Every round moves at least one item, so this ends.
	while result ~= nil do
		local now = get(window, index)
		if now == nil or now.item ~= result.item then
			break
		end
		result = quickMoveStack(window, index)
	end
end

-- SWAP (number keys over a slot): exchange the slot with hotbar slot `button + 1`.
local function swap(window: Window, index: number, button: number): { Stack }
	local inventory = window.inventory
	local hotbarSlot = button + 1
	local held = inventory.slots[hotbarSlot]
	if held ~= nil and held.count < 1 then
		held = nil
	end
	local current = get(window, index)
	if held == nil and current == nil then
		return {}
	end
	if held == nil then
		inventory.slots[hotbarSlot] = current
		set(window, index, nil)
	elseif current == nil then
		if mayPlace(window, index, held.item) then
			local max = maxStackFor(window, index, held.item)
			if held.count > max then
				set(window, index, make(held.item, max))
				inventory.slots[hotbarSlot] = make(held.item, held.count - max)
			else
				inventory.slots[hotbarSlot] = nil
				set(window, index, held)
			end
		end
	elseif mayPlace(window, index, held.item) then
		local max = maxStackFor(window, index, held.item)
		if held.count > max then
			-- Only part of the hotbar stack fits: the slot's old stack goes into the inventory.
			set(window, index, make(held.item, max))
			inventory.slots[hotbarSlot] = make(held.item, held.count - max)
			local left = Menu.add(inventory, current)
			return if left then { left } else {}
		end
		inventory.slots[hotbarSlot] = current
		set(window, index, held)
	end
	return {}
end

-- THROW (Q over a slot, empty cursor): one item (button 0) or the whole stack.
local function throw(window: Window, index: number, button: number): { Stack }
	local current = get(window, index)
	if current == nil then
		return {}
	end
	local taken = tryRemove(window, index, if button == 0 then 1 else current.count, math.huge)
	return if taken then { taken } else {}
end

--[[
	PICKUP_ALL (double click on an empty slot): gathers the carried item from the whole window (in
	window order, backwards for button 1) up to a full stack. The first pass leaves full stacks
	alone.
]]
local function pickupAll(window: Window, index: number, button: number)
	local carried = cursorOf(window)
	if carried == nil or get(window, index) ~= nil then
		return
	end
	local item = carried.item
	local max = Items.maxStack(item)
	local count = carried.count
	local size = Menu.size(window)
	local first = if button == 0 then 0 else size - 1
	local step = if button == 0 then 1 else -1
	for pass = 0, 1 do
		local slot = first
		while slot >= 0 and slot < size and count < max do
			local current = get(window, slot)
			if current and current.item == item and current.count <= max then
				if pass ~= 0 or current.count ~= Items.maxStack(current.item) then
					local taken = tryRemove(window, slot, current.count, max - count)
					if taken then
						count += taken.count
					end
				end
			end
			slot += step
		end
	end
	window.inventory.cursor = make(item, count)
end

local function click(window: Window, index: number, clickType: number, button: number, creative: boolean): { Stack }
	if not isInt(index) or not isInt(clickType) or not isInt(button) then
		return {}
	end
	local outside = index == OUTSIDE
	if not outside and (index < 0 or index >= Menu.size(window)) then
		return {}
	end
	if clickType == PICKUP or clickType == QUICK_MOVE then
		if button ~= 0 and button ~= 1 then
			return {}
		end
		if outside then
			-- Minecraft checks OUTSIDE before the click type: a shift click outside throws too.
			return throwCursor(window, button)
		elseif clickType == PICKUP then
			pickup(window, index, button)
		else
			quickMove(window, index)
		end
		return {}
	end
	if outside then
		return {}
	end
	if clickType == SWAP then
		if button < 0 or button >= HOTBAR then
			return {}
		end
		return swap(window, index, button)
	elseif clickType == CLONE then
		-- Middle click: a full stack of the slot's item on the empty cursor (creative only).
		local current = get(window, index)
		if creative and current and cursorOf(window) == nil then
			window.inventory.cursor = make(current.item, Items.maxStack(current.item))
		end
	elseif clickType == THROW then
		if (button == 0 or button == 1) and cursorOf(window) == nil then
			return throw(window, index, button)
		end
	elseif clickType == PICKUP_ALL then
		if button == 0 or button == 1 then
			pickupAll(window, index, button)
		end
	end
	return {}
end

--[[
	Quick craft (dragging the carried stack over slots), as Minecraft does it with QUICK_CRAFT start
	/ add / end. While adding, a slot counts if it is empty or holds the same item (even a full
	stack: canItemQuickReplace ignores the carried count), takes the item, and (modes 0 and 1) the
	cursor has more items than slots so far. One slot is a plain click with button = mode.
]]
local function drag(window: Window, mode: number, slots: { number })
	local carried = cursorOf(window)
	if carried == nil then
		return
	end
	local item = carried.item
	local max = Items.maxStack(item)
	local chosen: { number } = {}
	local seen: { [number]: boolean } = {}
	-- Numeric loop: apply validated exactly slots[1..#slots].
	for i = 1, #slots do
		local index = slots[i]
		local current = get(window, index)
		if
			not seen[index]
			and (current == nil or (current.item == item and current.count <= max))
			and mayPlace(window, index, item)
			and (mode == CLONE_DRAG or carried.count > #chosen)
		then
			seen[index] = true
			table.insert(chosen, index)
		end
	end
	if #chosen == 0 then
		return
	elseif #chosen == 1 then
		-- Minecraft turns it into a PICKUP click with button = mode (so mode 2 does nothing).
		if mode == SPLIT or mode == ONE then
			pickup(window, chosen[1], mode)
		end
		return
	end
	local each = if mode == SPLIT then math.floor(carried.count / #chosen) elseif mode == ONE then 1 else max
	local remaining = carried.count
	for _, index in chosen do
		local current = get(window, index)
		local have = if current then current.count else 0
		local total = math.min(each + have, math.min(max, maxStackFor(window, index, item)))
		remaining -= total - have
		set(window, index, make(item, total))
	end
	-- Mode 2 makes items out of nothing but still subtracts them, like Minecraft (the cursor
	-- usually ends up empty).
	window.inventory.cursor = make(item, remaining)
end

--[[ Actions ]]

--[[
	Applies one action to the window in place and returns the stacks thrown out of it (to drop as
	item entities). Invalid actions change nothing and return {}.
]]
function Menu.apply(window: Window, action: Action, creative: boolean): { Stack }
	if type(action) ~= "table" then
		return {}
	end
	local inventory = window.inventory
	if action.kind == "click" then
		if action.window ~= window.id then
			return {}
		end
		return click(window, action.slot, action.clickType, action.button, creative)
	elseif action.kind == "drag" then
		local mode, slots = action.mode, action.slots
		if action.window ~= window.id or type(slots) ~= "table" or #slots > Types.MAX_DRAG then
			return {}
		end
		if mode ~= SPLIT and mode ~= ONE and not (mode == CLONE_DRAG and creative) then
			return {}
		end
		local size = Menu.size(window)
		for i = 1, #slots do
			local index = slots[i]
			if not isInt(index) or index < 0 or index >= size then
				return {}
			end
		end
		drag(window, mode, slots)
		return {}
	elseif action.kind == "select" then
		local slot = action.slot
		if isInt(slot) and slot >= 1 and slot <= HOTBAR then
			inventory.selected = slot
		end
		return {}
	elseif action.kind == "drop" then
		-- The Q key: one of the held item, or the stack (Ctrl+Q).
		local selected = inventory.selected
		if not isInt(selected) or selected < 1 or selected > HOTBAR then
			return {}
		end
		local held = inventory.slots[selected]
		if held == nil or held.count < 1 then
			return {}
		end
		local n = if action.all == true then held.count else 1
		inventory.slots[selected] = make(held.item, held.count - n)
		return { { item = held.item, count = n } }
	elseif action.kind == "place" then
		-- Placing a block uses one up (survival). Creative keeps everything.
		local selected = inventory.selected
		if creative or not isInt(selected) or selected < 1 or selected > HOTBAR then
			return {}
		end
		local held = inventory.slots[selected]
		if held and held.count >= 1 and held.item == action.item and Items.isValid(held.item) then
			inventory.slots[selected] = make(held.item, held.count - 1)
		end
		return {}
	elseif action.kind == "creative" then
		local slot, item, count = action.slot, action.item, action.count
		if not creative or action.window ~= window.id or not isInt(slot) or not isInt(count) or count < 0 then
			return {}
		end
		if count > 0 and not (isInt(item) and Items.isValid(item)) then
			return {}
		end
		if slot == CURSOR then
			if count > Items.maxStack(item) then
				return {}
			end
			inventory.cursor = make(item, count)
			return {}
		end
		if slot < 0 or slot >= Menu.size(window) then
			return {}
		end
		if count > 0 and (not mayPlace(window, slot, item) or count > maxStackFor(window, slot, item)) then
			return {}
		end
		set(window, slot, make(item, count))
		return {}
	elseif action.kind == "close" then
		if action.window ~= window.id then
			return {}
		end
		return Menu.close(window)
	end
	return {}
end

--[[ Whole inventories ]]

-- Closing a screen: the carried stack goes back into the inventory; returns what did not fit.
function Menu.close(window: Window): { Stack }
	local inventory = window.inventory
	local carried = cursorOf(window)
	inventory.cursor = nil
	if carried == nil then
		return {}
	end
	local left = Menu.add(inventory, carried)
	return if left then { left } else {}
end

-- Empties the inventory, armor and cursor (death) and returns the stacks.
function Menu.clear(inventory: Inventory): { Stack }
	local stacks: { Stack } = {}
	local function take(stack: Stack?)
		if stack and stack.count >= 1 then
			table.insert(stacks, { item = stack.item, count = stack.count })
		end
	end
	for slot = 1, INVENTORY do
		take(inventory.slots[slot])
		inventory.slots[slot] = nil
	end
	for slot = 1, ARMOR do
		take(inventory.armor[slot])
		inventory.armor[slot] = nil
	end
	take(inventory.cursor)
	inventory.cursor = nil
	return stacks
end

-- Deep copy (stacks too).
function Menu.copyInventory(inventory: Inventory): Inventory
	local slots: { [number]: Stack? } = {}
	for slot = 1, INVENTORY do
		slots[slot] = copy(inventory.slots[slot])
	end
	local armor: { [number]: Stack? } = {}
	for slot = 1, ARMOR do
		armor[slot] = copy(inventory.armor[slot])
	end
	return { slots = slots, armor = armor, cursor = copy(inventory.cursor), selected = inventory.selected }
end

-- Deep copy (inventory, container and stacks).
function Menu.copyWindow(window: Window): Window
	local container = window.container
	local copied: Container? = nil
	if container then
		local slots: { [number]: Stack? } = {}
		for slot = 1, container.size do
			slots[slot] = copy(container.slots[slot])
		end
		copied = { block = container.block, size = container.size, slots = slots }
	end
	return { id = window.id, inventory = Menu.copyInventory(window.inventory), container = copied }
end

--[[ Pick block ]]

-- Inventory.getSuitableHotbarSlot: the first empty hotbar slot from the selected one on, else the
-- selected one.
local function suitableHotbarSlot(inventory: Inventory): number
	local selected = inventory.selected
	if not isInt(selected) or selected < 1 or selected > HOTBAR then
		selected = 1
	end
	for i = 0, HOTBAR - 1 do
		local slot = (selected - 1 + i) % HOTBAR + 1
		local stack = inventory.slots[slot]
		if stack == nil or stack.count < 1 then
			return slot
		end
	end
	return selected
end

--[[
	The actions Minecraft's pick block (middle click on a block) performs, to apply in order on
	window 0 (none when nothing happens):
	  * the item in the hotbar: select it;
	  * in slots 10..36: swap it into a suitable hotbar slot and select that;
	  * nowhere (creative only): put a full stack in a suitable hotbar slot (moving what was there
	    to a free slot, if any, like Inventory.setPickedItem) and select it.
]]
function Menu.pickBlock(inventory: Inventory, item: number, creative: boolean): { Action }
	if not isInt(item) or not Items.isValid(item) then
		return {}
	end
	local window: Window = { id = 0, inventory = inventory, container = nil }
	local found: number? = nil
	for slot = 1, INVENTORY do
		local stack = inventory.slots[slot]
		if stack and stack.count >= 1 and stack.item == item then
			found = slot
			break
		end
	end
	if found and found <= HOTBAR then
		return { { kind = "select", slot = found } }
	end
	local target = suitableHotbarSlot(inventory)
	local actions: { Action } = {}
	if found then
		table.insert(actions, {
			kind = "click",
			window = 0,
			slot = Menu.windowIndex(window, "inventory", found) :: number,
			clickType = SWAP,
			button = target - 1,
		})
	elseif creative then
		local current = inventory.slots[target]
		if current and current.count >= 1 then
			for slot = HOTBAR + 1, INVENTORY do
				local stack = inventory.slots[slot]
				if stack == nil or stack.count < 1 then
					-- Swapping with an empty slot moves the hotbar stack there.
					table.insert(actions, {
						kind = "click",
						window = 0,
						slot = Menu.windowIndex(window, "inventory", slot) :: number,
						clickType = SWAP,
						button = target - 1,
					})
					break
				end
			end
		end
		table.insert(actions, {
			kind = "creative",
			window = 0,
			slot = Menu.windowIndex(window, "inventory", target) :: number,
			item = item,
			count = Items.maxStack(item),
		})
	else
		return {}
	end
	table.insert(actions, { kind = "select", slot = target })
	return actions
end

return Menu
