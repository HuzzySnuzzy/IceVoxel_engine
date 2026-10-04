--!strict
--[[
	JEI's recipe transfer (the "+" button): moving a crafting recipe's ingredients from the
	inventory into the open crafting grid, as ordinary inventory actions. Pure: no Roblox APIs, so
	the tests apply the plans with Inventory/Menu and check the grid.

	The grid is the open window's crafting container: window 0's 2 x 2 (the inventory screen) or a
	crafting table's 3 x 3. The recipe goes where the recipe view draws it (JeiData.craftingGrid):
	on a table cell for cell; on the 2 x 2 the view's top left 2 x 2 (cells 1, 2, 4, 5), which holds
	every recipe that fits there (JEI's PlayerRecipeTransferHandler). Bigger recipes are refused.

	`plan(window, recipe, all)` returns the actions, in order:
	  1. a stack carried by the mouse is put down in the inventory (PICKUP clicks);
	  2. the grid is emptied into the inventory (shift clicks, QUICK_MOVE), as JEI does first;
	  3. for each ingredient item, a stack of it is picked up (PICKUP), spread over the cells that
	     take it with a drag (Split when an even share fits, else One: one item per cell, exactly),
	     and what is left is put back where it came from.
	`all` (shift on the "+") places as many sets as the inventory has, up to a stack (JEI's max
	transfer); otherwise one set. Ingredients that a tag accepts in several items go to the item
	the inventory has most of, so a set usually uses one kind of planks.

	Every plan is applied to a copy of the window with Menu.apply before it is returned and must
	leave exactly the recipe in the grid (and its result in the result slot), nothing on the
	cursor and every item still there; otherwise there is no plan. So the client can send the
	actions through ClientInventory.apply (predicted, then checked by the server) knowing what they
	do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Crafting = require(Shared.Crafting)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local JeiData = require(script.Parent.JeiData)

type Window = Types.Window
type Action = Types.Action
type Stack = Types.Stack

export type Status = {
	-- Can the recipe be moved into the grid now?
	ok: boolean,
	-- Why not, for the button's tooltip.
	reason: string?,
	-- Display cells (1..9, JeiData.craftingGrid) the inventory cannot fill.
	missing: { [number]: boolean },
}

local JeiTransfer = {}

JeiTransfer.TOO_LARGE = "Recipe too large for this grid"
JeiTransfer.MISSING = "Missing items"
JeiTransfer.NO_GRID = "No crafting grid open"
JeiTransfer.NO_ROOM = "No room in the inventory"
JeiTransfer.FAILED = "Could not move the items"

local PICKUP, QUICK_MOVE = Menu.ClickType.Pickup, Menu.ClickType.QuickMove
local SPLIT, ONE = Menu.DragMode.Split, Menu.DragMode.One
local LEFT, RIGHT = 0, 1
-- On the 2 x 2 grid: the display cells it takes, and their grid cells (1..4).
local SMALL_GRID: { [number]: number } = { [1] = 1, [2] = 2, [4] = 3, [5] = 4 }

-- Width of the open crafting grid (2 or 3), or 0 when the window has none.
function JeiTransfer.gridWidth(window: Window): number
	local container = window.container
	local width = Types.craftWidth(container)
	if container == nil or width == 0 or container.size ~= Types.CRAFT_RESULT + width * width then
		return 0
	end
	return width
end

--[[
	Where each display cell of `recipe` goes in a grid `width` wide: display cell -> window slot
	(the grid's slots are window slots 1..width^2). nil when the recipe does not fit.
]]
function JeiTransfer.targets(recipe: Crafting.Recipe, width: number): { [number]: number }?
	if width ~= 2 and width ~= 3 then
		return nil
	end
	local targets: { [number]: number } = {}
	for cell in JeiData.craftingGrid(recipe) do
		if width == 3 then
			targets[cell] = cell
		else
			local small = SMALL_GRID[cell]
			if small == nil then
				return nil
			end
			targets[cell] = small
		end
	end
	return targets
end

--[[ Counting what the inventory has ]]

-- A kind of stack: the item and its wear (stacks only join when both match).
type Kind = { item: number, damage: number, total: number, key: string }

local function wearOf(stack: Stack): number
	return if stack.damage and stack.damage >= 1 then stack.damage else 0
end

local function keyOf(item: number, damage: number): string
	return `{item}:{damage}`
end

-- Totals by kind of the stacks in `stacks`, in first-seen order.
local function count(stacks: { Stack }): { Kind }
	local kinds: { Kind } = {}
	local byKey: { [string]: Kind } = {}
	for _, stack in stacks do
		if stack.count >= 1 then
			local damage = wearOf(stack)
			local key = keyOf(stack.item, damage)
			local kind = byKey[key]
			if kind == nil then
				kind = { item = stack.item, damage = damage, total = 0, key = key }
				byKey[key] = kind
				table.insert(kinds, kind)
			end
			kind.total += stack.count
		end
	end
	return kinds
end

-- The window's grid slots (window slots 1..width^2).
local function gridSlots(width: number): { number }
	local slots: { number } = {}
	for i = 1, width * width do
		table.insert(slots, Types.CRAFT_RESULT - 1 + i)
	end
	return slots
end

-- Window slots of the inventory (1..36: the hotbar first, like Menu.add).
local function inventorySlots(window: Window): { number }
	local slots: { number } = {}
	for i = 1, Types.INVENTORY_SIZE do
		table.insert(slots, Menu.windowIndex(window, "inventory", i) :: number)
	end
	return slots
end

-- Everything the transfer may use: the inventory, the grid (emptied first) and the cursor.
local function supply(window: Window, width: number): { Stack }
	local stacks: { Stack } = {}
	for i = 1, Types.INVENTORY_SIZE do
		local stack = window.inventory.slots[i]
		if stack then
			table.insert(stacks, stack)
		end
	end
	for _, slot in gridSlots(width) do
		local stack = Menu.get(window, slot)
		if stack then
			table.insert(stacks, stack)
		end
	end
	local cursor = window.inventory.cursor
	if cursor then
		table.insert(stacks, cursor)
	end
	return stacks
end

--[[
	Gives every display cell a kind of stack with `sets` items to spare, cells in order, each the
	kind it accepts that has the most left (ties: the first). Returns cell -> kind, and the cells
	nothing was left for.
]]
local function allocate(
	grid: { [number]: { number } },
	kinds: { Kind },
	sets: number
): ({ [number]: Kind }, { [number]: boolean })
	local left: { [string]: number } = {}
	for _, kind in kinds do
		left[kind.key] = kind.total
	end
	local chosen: { [number]: Kind } = {}
	local missing: { [number]: boolean } = {}
	for cell = 1, 9 do
		local accepts = grid[cell]
		if accepts then
			local best: Kind? = nil
			for _, kind in kinds do
				if
					table.find(accepts, kind.item)
					and left[kind.key] >= sets
					and Items.maxStack(kind.item) >= sets
					and (best == nil or left[kind.key] > left[best.key])
				then
					best = kind
				end
			end
			if best then
				chosen[cell] = best
				left[best.key] -= sets
			else
				missing[cell] = true
			end
		end
	end
	return chosen, missing
end

--[[
	Can `recipe` be moved into the window's grid? Says why not, and which display cells the
	inventory (with the grid and the cursor) cannot fill.
]]
function JeiTransfer.check(window: Window, recipe: Crafting.Recipe): Status
	local width = JeiTransfer.gridWidth(window)
	if width == 0 then
		return { ok = false, reason = JeiTransfer.NO_GRID, missing = {} }
	end
	if JeiTransfer.targets(recipe, width) == nil then
		return { ok = false, reason = JeiTransfer.TOO_LARGE, missing = {} }
	end
	local _, missing = allocate(JeiData.craftingGrid(recipe), count(supply(window, width)), 1)
	if next(missing) ~= nil then
		return { ok = false, reason = JeiTransfer.MISSING, missing = missing }
	end
	return { ok = true, reason = nil, missing = {} }
end

--[[
	The "+" button's state: `check`, and when that passes, whether the one set plan can really be
	made (the carried stack and the grid's contents need room in the inventory first: "No room in
	the inventory"), so a lit button always moves something.
]]
function JeiTransfer.status(window: Window, recipe: Crafting.Recipe, creative: boolean?): Status
	local status = JeiTransfer.check(window, recipe)
	if not status.ok then
		return status
	end
	local actions, reason = JeiTransfer.plan(window, recipe, false, creative)
	if actions == nil then
		return { ok = false, reason = reason or JeiTransfer.FAILED, missing = {} }
	end
	return status
end

-- How many sets of `recipe` the inventory (with the grid and cursor) holds, up to a stack.
function JeiTransfer.sets(window: Window, recipe: Crafting.Recipe): number
	local width = JeiTransfer.gridWidth(window)
	if width == 0 then
		return 0
	end
	local grid = JeiData.craftingGrid(recipe)
	local kinds = count(supply(window, width))
	local sets = 0
	for n = 1, Items.MAX_STACK do
		local _, missing = allocate(grid, kinds, n)
		if next(missing) ~= nil then
			break
		end
		sets = n
	end
	return sets
end

--[[ Planning ]]

-- Item counts by kind key of the whole window, cursor included.
local function census(window: Window): { [string]: number }
	local totals: { [string]: number } = {}
	local function note(stack: Stack?)
		if stack and stack.count >= 1 then
			local key = keyOf(stack.item, wearOf(stack))
			totals[key] = (totals[key] or 0) + stack.count
		end
	end
	for slot = 0, Menu.size(window) - 1 do
		-- (A crafting result is not an item yet: it only exists while the grid holds the recipe.)
		if not Menu.isCraftResult(window, slot) then
			note(Menu.get(window, slot))
		end
	end
	note(window.inventory.cursor)
	return totals
end

local function sameTotals(a: { [string]: number }, b: { [string]: number }): boolean
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key, value in b do
		if a[key] ~= value then
			return false
		end
	end
	return true
end

--[[
	Builds the actions on a copy of the window (`sim`), applying each as it goes, so every step
	sees the result of the ones before.
]]
type Builder = { sim: Window, actions: { Action }, creative: boolean }

local function push(b: Builder, action: Action)
	table.insert(b.actions, action)
	Menu.apply(b.sim, action, b.creative)
end

local function clickSlot(b: Builder, slot: number, clickType: number)
	push(b, { kind = "click", window = b.sim.id, slot = slot, clickType = clickType, button = LEFT })
end

local function matches(stack: Stack?, kind: Kind): boolean
	return stack ~= nil and stack.item == kind.item and wearOf(stack) == kind.damage
end

-- Puts the carried stack down in the inventory: on stacks of it with room, then an empty slot.
local function stow(b: Builder): boolean
	for _ = 1, Types.INVENTORY_SIZE + 1 do
		local cursor = b.sim.inventory.cursor
		if cursor == nil or cursor.count < 1 then
			return true
		end
		local target: number? = nil
		for _, slot in inventorySlots(b.sim) do
			local stack = Menu.get(b.sim, slot)
			if stack and Menu.stacksMatch(stack, cursor) and stack.count < Items.maxStack(stack.item) then
				target = slot
				break
			end
		end
		if target == nil then
			for _, slot in inventorySlots(b.sim) do
				if Menu.get(b.sim, slot) == nil then
					target = slot
					break
				end
			end
		end
		if target == nil then
			return false
		end
		clickSlot(b, target, PICKUP)
	end
	local cursor = b.sim.inventory.cursor
	return cursor == nil or cursor.count < 1
end

--[[
	Spreads `kind` over the grid `cells` until each holds `sets` (false: the inventory ran out).
	Each round looks at the cells still short and at the carried stack (picked up whole, the
	biggest there is, when the cursor is empty):
	  * an even share of it fits every short cell: one Split drag places it all;
	  * fewer items than cells: one One drag, an item each for as many cells as there are items;
	  * too many (the share would overfill a cell): with only a little more to place than the
	    cells need, the excess goes back home an item at a time (right clicks) until a Split fits
	    exactly; with much more, the stack goes back home and half of it is taken (halving once
	    per pickup); else One drags.
	A step that changed nothing ends it (false), so it never loops.
]]
local function fill(b: Builder, kind: Kind, cells: { number }, sets: number): boolean
	local home: number? = nil
	local halved = false
	local function signature(): number
		local cursor = b.sim.inventory.cursor
		local total = if cursor then cursor.count else 0
		for _, cell in cells do
			local stack = Menu.get(b.sim, cell)
			total += if stack then stack.count * 1000 else 0
		end
		return total
	end
	for _ = 1, 4 * (#cells * sets + Types.INVENTORY_SIZE) do
		local short: { number } = {}
		local least = math.huge
		for _, cell in cells do
			local stack = Menu.get(b.sim, cell)
			local have = if stack then stack.count else 0
			if have < sets then
				table.insert(short, cell)
				least = math.min(least, sets - have)
			end
		end
		if #short == 0 then
			break
		end
		local cursor: Stack? = b.sim.inventory.cursor
		if cursor == nil or cursor.count < 1 then
			-- Pick up the biggest stack of it (fewest rounds).
			local best: number?, most = nil, 0
			for _, slot in inventorySlots(b.sim) do
				local stack = Menu.get(b.sim, slot)
				if matches(stack, kind) and (stack :: Stack).count > most then
					best, most = slot, (stack :: Stack).count
				end
			end
			if best == nil then
				return false
			end
			home, halved = best, false
			clickSlot(b, best, PICKUP)
			cursor = b.sim.inventory.cursor
		end
		if cursor == nil or home == nil then
			return false
		end
		local before = signature()
		local carried, k = cursor.count, #short
		local excess = carried - k * least
		if carried < k then
			push(b, {
				kind = "drag",
				window = b.sim.id,
				mode = ONE,
				slots = table.move(short, 1, carried, 1, {}),
			})
		elseif carried // k <= least then
			-- An even share fits everywhere: one drag places it all.
			push(b, { kind = "drag", window = b.sim.id, mode = SPLIT, slots = short })
		elseif least > 2 and excess < least then
			-- One back home (a right click places one).
			push(b, { kind = "click", window = b.sim.id, slot = home, clickType = PICKUP, button = RIGHT })
		elseif least > 2 and not halved and Menu.get(b.sim, home) == nil then
			-- Everything back home, then half of it up again (a right click takes half).
			halved = true
			clickSlot(b, home, PICKUP)
			push(b, { kind = "click", window = b.sim.id, slot = home, clickType = PICKUP, button = RIGHT })
		else
			-- One more in every short cell.
			push(b, { kind = "drag", window = b.sim.id, mode = ONE, slots = short })
		end
		if signature() == before then
			return false
		end
	end
	-- What is left goes back where it came from.
	local cursor = b.sim.inventory.cursor
	if cursor and cursor.count >= 1 and home then
		clickSlot(b, home, PICKUP)
	end
	return stow(b)
end

--[[
	The actions that move `recipe` into the window's crafting grid: one set, or as many as the
	inventory has (up to a stack) with `all`. nil and the reason when it cannot be done (see check),
	or when the result would not be exactly the recipe. `creative` is the game mode the actions
	are applied in (it changes nothing here, but Menu.apply takes it).
]]
function JeiTransfer.plan(
	window: Window,
	recipe: Crafting.Recipe,
	all: boolean?,
	creative: boolean?
): ({ Action }?, string?)
	local status = JeiTransfer.check(window, recipe)
	if not status.ok then
		return nil, status.reason
	end
	local width = JeiTransfer.gridWidth(window)
	local targets = JeiTransfer.targets(recipe, width) :: { [number]: number }
	local sets = if all then JeiTransfer.sets(window, recipe) else 1
	if sets < 1 then
		return nil, JeiTransfer.MISSING
	end
	local before = census(window)
	local b: Builder = { sim = Menu.copyWindow(window), actions = {}, creative = creative == true }

	-- 1. Nothing on the cursor; 2. an empty grid.
	if not stow(b) then
		return nil, JeiTransfer.NO_ROOM
	end
	for _, slot in gridSlots(width) do
		if Menu.get(b.sim, slot) then
			clickSlot(b, slot, QUICK_MOVE)
			if Menu.get(b.sim, slot) then
				return nil, JeiTransfer.NO_ROOM
			end
		end
	end

	-- 3. Each kind of stack over its cells.
	local grid = JeiData.craftingGrid(recipe)
	local chosen, missing = allocate(grid, count(supply(b.sim, width)), sets)
	if next(missing) ~= nil then
		return nil, JeiTransfer.MISSING
	end
	local order: { Kind } = {}
	local cellsOf: { [Kind]: { number } } = {}
	for cell = 1, 9 do
		local kind = chosen[cell]
		if kind then
			local list = cellsOf[kind]
			if list == nil then
				list = {}
				cellsOf[kind] = list
				table.insert(order, kind)
			end
			table.insert(list, targets[cell])
		end
	end
	for _, kind in order do
		if not fill(b, kind, cellsOf[kind], sets) then
			return nil, JeiTransfer.FAILED
		end
	end

	-- The grid holds exactly the recipe, the result is the recipe's, and nothing was lost.
	local sim = b.sim
	local used: { [number]: boolean } = {}
	for cell, slot in targets do
		used[slot] = true
		local stack = Menu.get(sim, slot)
		if stack == nil or stack.count ~= sets or not table.find(grid[cell], stack.item) then
			return nil, JeiTransfer.FAILED
		end
	end
	for _, slot in gridSlots(width) do
		if not used[slot] and Menu.get(sim, slot) then
			return nil, JeiTransfer.FAILED
		end
	end
	local result = Menu.get(sim, Types.CRAFT_RESULT - 1)
	local cursor = sim.inventory.cursor
	if result == nil or result.item ~= recipe.result or (cursor and cursor.count >= 1) then
		return nil, JeiTransfer.FAILED
	end
	if not sameTotals(before, census(sim)) then
		return nil, JeiTransfer.FAILED
	end
	return b.actions, nil
end

return JeiTransfer
