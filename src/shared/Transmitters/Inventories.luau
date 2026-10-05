--!strict
--[[
	Sided item inventories for Logistical Transporters: which container slots items may enter and
	leave through each face of a block, and pure insert / extract maths on a container's slots.
	Shared/Transmitters re-exports all of it; use that.

	Faces are sides 0..5 (Down, Up, North, South, West, East: Transmitters.SIDES), and face f of a
	block is its face towards block + offset(f): a transporter on top of a furnace reaches it
	through the furnace's face Up (1).

	  furnace  Minecraft's AbstractFurnaceBlockEntity, a WorldlyContainer (slots 1 input, 2 fuel,
	           3 output; `menu = "Furnace"`):
	             slots for a face        Up {input}, Down {output, fuel}, the sides {fuel}
	             what may go in          the input anything, the fuel only what burns
	                                     (Smelting.fuel > 0), the output nothing
	             what may come out       anything, except the fuel slot through Down, which only
	                                     gives buckets (Minecraft's canTakeItemThroughFace: the
	                                     bucket a lava bucket leaves)
	  chest    a plain Container: every slot, through every face, anything. So is any other block
	           with a `container`.

	Inserting (`insert`, `room`) follows Forge's ItemHandlerHelper.insertItemStacked, as Mekanism's
	transporters insert: first it tops up stacks of the same item and wear (Menu.stacksMatch) in
	slot order, then it fills empty slots in order, never beyond the item's max stack (at most 64,
	a container's limit). (Minecraft's hopper goes slot by slot instead, merging or filling as it
	meets them.)

	Extracting is Mekanism's TransitRequest: `available` lists the item types that may leave
	through a face with the total of each over its slots, and `extract` takes up to n of one type
	from those slots in order. A transporter carries at most one stack, so `extract` never takes
	more than the item's max stack (tools one at a time).

	Everything is pure. Slots come in as `{ [slot]: Stack? }` and new tables come out: an input is
	never changed and a changed slot gets a new stack table (as in Inventory/Menu), so the server
	simulates (finds where an item can go) with the same calls it applies.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Items = require(script.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Crafting.Smelting)
local Menu = require(script.Parent.Parent.Inventory.Menu)
local Types = require(script.Parent.Parent.Inventory.Types)

type Stack = Items.Stack
export type Slots = { [number]: Stack? }

local Inventories = {}

local DOWN = 0
-- Minecraft's furnace slots (1 input, 2 fuel, 3 output).
local INPUT, FUEL, OUTPUT = Types.FURNACE_INPUT, Types.FURNACE_FUEL, Types.FURNACE_OUTPUT
local stacksMatch = Menu.stacksMatch

local FURNACE_SLOTS: { [number]: { number } } = table.freeze({
	[0] = table.freeze({ OUTPUT, FUEL }),
	[1] = table.freeze({ INPUT }),
	[2] = table.freeze({ FUEL }),
	[3] = table.freeze({ FUEL }),
	[4] = table.freeze({ FUEL }),
	[5] = table.freeze({ FUEL }),
})
local NO_SLOTS: { number } = table.freeze({})
-- What the furnace's fuel slot gives through its bottom.
local BUCKETS: { [number]: boolean } = { [Items.id.Bucket] = true, [Items.id.WaterBucket] = true }

-- Per block id: "furnace", "chest" (any other container) or nil, and a chest's slot list.
local kinds: { [number]: string } = {}
local allSlots: { [number]: { number } } = {}
for id = 0, Blocks.count - 1 do
	local def = Blocks.get(id)
	if def.container > 0 then
		if def.menu == "Furnace" then
			assert(def.container == 3, `Furnace {def.name} must have 3 slots`)
			kinds[id] = "furnace"
		else
			kinds[id] = "chest"
			local list = table.create(def.container)
			for slot = 1, def.container do
				list[slot] = slot
			end
			allSlots[id] = table.freeze(list)
		end
	end
end

local function isFace(face: number): boolean
	return face == 0 or face == 1 or face == 2 or face == 3 or face == 4 or face == 5
end

-- A tool's wear as kept in a stack (Menu's rule: a positive whole number, else nil).
local function cleanDamage(damage: number?): number?
	if type(damage) == "number" and damage >= 1 and damage == math.floor(damage) then
		return damage
	end
	return nil
end

local function make(item: number, count: number, damage: number?): Stack?
	if count < 1 then
		return nil
	end
	return { item = item, count = count, damage = cleanDamage(damage) }
end

local function isStack(stack: Stack?): boolean
	return stack ~= nil
		and type(stack.count) == "number"
		and stack.count >= 1
		and stack.count == math.floor(stack.count)
		and Items.isValid(stack.item)
end

-- The most of `item` one container slot holds (Container.getMaxStackSize is 64).
local function slotMax(item: number): number
	return math.min(Items.maxStack(item), Items.MAX_STACK)
end

-- Does `block` keep items (a chest or a furnace: BlockList `container`)?
function Inventories.isInventory(block: number): boolean
	return kinds[block] ~= nil
end

-- The slots items may enter `block` by through `face`, in the order they are tried (do not
-- change the list). Empty for blocks without slots and bad faces.
function Inventories.insertSlots(block: number, face: number): { number }
	local kind = kinds[block]
	if kind == nil or not isFace(face) then
		return NO_SLOTS
	elseif kind == "furnace" then
		return FURNACE_SLOTS[face]
	end
	return allSlots[block]
end

-- The slots items may be taken from through `face`, in order (WorldlyContainer.getSlotsForFace:
-- the same slots as for inserting).
function Inventories.extractSlots(block: number, face: number): { number }
	return Inventories.insertSlots(block, face)
end

-- The item rules of a slot the face reaches (canPlaceItem / canTakeItemThroughFace), for the
-- loops below, which only visit such slots.
local function mayPlace(block: number, slot: number, item: number): boolean
	if kinds[block] == "furnace" then
		if slot == OUTPUT then
			return false
		elseif slot == FUEL then
			return Smelting.fuel(item) > 0
		end
	end
	return true
end

local function mayTake(block: number, face: number, slot: number, item: number): boolean
	if kinds[block] == "furnace" and face == DOWN and slot == FUEL then
		return BUCKETS[item] == true
	end
	return true
end

-- May `item` enter `slot` of `block` through `face` (Minecraft's canPlaceItemThroughFace)?
function Inventories.canInsert(block: number, face: number, slot: number, item: number): boolean
	return Items.isValid(item)
		and table.find(Inventories.insertSlots(block, face), slot) ~= nil
		and mayPlace(block, slot, item)
end

-- May `item` be taken from `slot` of `block` through `face` (canTakeItemThroughFace)?
function Inventories.canExtract(block: number, face: number, slot: number, item: number): boolean
	return Items.isValid(item)
		and table.find(Inventories.extractSlots(block, face), slot) ~= nil
		and mayTake(block, face, slot, item)
end

--[[
	How many of `stack` would go into `slots` of `block` through `face` (0..stack.count), as
	`insert` would put them: room on stacks of the same item and wear, then empty slots that take
	it.
]]
function Inventories.room(block: number, face: number, slots: Slots, stack: Stack): number
	if not isStack(stack) then
		return 0
	end
	local item, max = stack.item, slotMax(stack.item)
	local room = 0
	for _, slot in Inventories.insertSlots(block, face) do
		if mayPlace(block, slot, item) then
			local current = slots[slot]
			if current == nil or current.count < 1 then
				room += max
			elseif stacksMatch(current, stack) and current.count < max then
				room += max - current.count
			end
			if room >= stack.count then
				return stack.count
			end
		end
	end
	return room
end

--[[
	`stack` put into `slots` of `block` through `face`: the new slots and what is left over (nil:
	all of it went in). Stacks of the same item and wear are topped up first, in slot order, then
	empty slots are filled in order.
]]
function Inventories.insert(block: number, face: number, slots: Slots, stack: Stack): (Slots, Stack?)
	local out = table.clone(slots)
	if not isStack(stack) then
		-- Nothing goes in: a stack of an unknown item is all left over.
		local some = type(stack.count) == "number" and stack.count >= 1
		return out, if some then make(stack.item, math.floor(stack.count), stack.damage) else nil
	end
	local item, damage, max = stack.item, cleanDamage(stack.damage), slotMax(stack.item)
	local left = stack.count
	local order = Inventories.insertSlots(block, face)
	-- Top up matching stacks first...
	for _, slot in order do
		if left < 1 then
			break
		end
		local current = out[slot]
		if
			current ~= nil
			and current.count >= 1
			and current.count < max
			and stacksMatch(current, stack)
			and mayPlace(block, slot, item)
		then
			local put = math.min(left, max - current.count)
			out[slot] = make(item, current.count + put, damage)
			left -= put
		end
	end
	-- ...then fill empty slots.
	for _, slot in order do
		if left < 1 then
			break
		end
		local current = out[slot]
		if (current == nil or current.count < 1) and mayPlace(block, slot, item) then
			local put = math.min(left, max)
			out[slot] = make(item, put, damage)
			left -= put
		end
	end
	return out, make(item, left, damage)
end

--[[
	The item types that may be taken out of `slots` of `block` through `face`, in the order of their
	first slot, each with its total count over all those slots (which may be more than a stack).
	Mekanism's TransitRequest: a transporter looks for somewhere to send each type, in this order,
	before it takes anything.
]]
function Inventories.available(block: number, face: number, slots: Slots): { Stack }
	local found: { Stack } = {}
	for _, slot in Inventories.extractSlots(block, face) do
		local current = slots[slot]
		if current ~= nil and isStack(current) and mayTake(block, face, slot, current.item) then
			local merged = false
			for _, entry in found do
				if stacksMatch(entry, current) then
					entry.count += current.count
					merged = true
					break
				end
			end
			if not merged then
				table.insert(
					found,
					{ item = current.item, count = current.count, damage = cleanDamage(current.damage) }
				)
			end
		end
	end
	return found
end

--[[
	Takes up to `count` items like `match` (the same item and wear; nil: the first type `available`
	lists) out of `slots` of `block` through `face`, from its slots in order: the new slots and the
	stack taken (nil: nothing). Never more than the item's max stack.
]]
function Inventories.extract(block: number, face: number, slots: Slots, count: number, match: Stack?): (Slots, Stack?)
	local out = table.clone(slots)
	local wanted = match or Inventories.available(block, face, slots)[1]
	-- (NaN fails `count >= 1`.)
	if wanted == nil or not Items.isValid(wanted.item) or type(count) ~= "number" or not (count >= 1) then
		return out, nil
	end
	local item = wanted.item
	local left = math.min(math.floor(count), slotMax(item))
	local taken = 0
	for _, slot in Inventories.extractSlots(block, face) do
		if left < 1 then
			break
		end
		local current = out[slot]
		if
			current ~= nil
			and isStack(current)
			and stacksMatch(current, wanted)
			and mayTake(block, face, slot, item)
		then
			local take = math.min(left, current.count)
			out[slot] = make(item, current.count - take, current.damage)
			left -= take
			taken += take
		end
	end
	return out, make(item, taken, wanted.damage)
end

return Inventories
