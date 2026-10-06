--!strict
--[[
	Sided item inventories for Logistical Transporters: which container slots items may enter and
	leave through each face of a block, which slots a block pushes out on its own, and pure insert
	/ extract maths on a container's slots. Shared/Transmitters re-exports all of it; use that.

	Faces are sides 0..5 (Down, Up, North, South, West, East: Transmitters.SIDES), and face f of a
	block is its face towards block + offset(f): a transporter on top of a furnace reaches it
	through the furnace's face Up (1).

	Furnaces and machines follow Mekanism's machine rules, the same through every face. (This used
	to be Minecraft's WorldlyContainer for furnaces: fuel through the sides, so a transporter
	pulling from a furnace's side took its fuel straight back out. Players asked for Mekanism's
	logic instead: automation puts ore and fuel in and only ever takes the results out.)

	  furnace  Minecraft's furnace (slots 1 input, 2 fuel, 3 output; `menu = "Furnace"`) with
	           Mekanism's slot rules on every face:
	             in     {input, fuel}: the input takes only what smelts (Mekanism's input slots
	                    take only valid recipe inputs: Smelting.result), the fuel only what burns
	                    (Smelting.fuel > 0), the output nothing. So ore goes into the input, coal
	                    into the fuel, and logs (both) into the input, then the fuel when the
	                    input can't take them (`insert` fills a furnace slot by slot, in this
	                    order, as Mekanism inserts into a machine's slots)
	             out    {output, fuel}: the results, and from the fuel slot only what no longer
	                    burns (an empty bucket: Mekanism's FuelInventorySlot gives automation
	                    nothing else); never the input or the fuel
	             eject  {output} (below)
	  machine  a Mekanism machine with slots (Shared/Machines): its kind says which slots each face
	           reaches (by default every face puts items into its inputs and takes them out of its
	           outputs), what each slot takes (Machines.mayPlace) and how many (Machines.slotLimit),
	           and its output slots are ejected (Machines.outputSlots); a slot may give only some
	           items (Machines.mayTake). The Heat Generator takes fuel through every face and gives
	           only what no longer burns (the empty Bucket a Lava Bucket leaves, as the furnace's
	           fuel slot does); the Electric Furnace (Machines/Kinds/Smelter) takes what smelts
	           and gives its results through every face.
	           Upgrade slots are out of reach (Machines/Upgrades), so a machine with nothing else
	           (the Solar Panel) is no inventory at all: no transporter connects to it.
	  chest    a plain Container: every slot, through every face, anything. So is any other block
	           with a `container` (`isPlain`).

	Ejecting (Mekanism's ejector: `ejects`, `ejectSlots`, `results`, `takeResults`). A furnace and a
	machine with output slots push what those hold out on their own: into the transporters around
	them whose side receives from them (NORMAL or PULL: server Transmitters/Transport) and into
	the plain inventories next to them (server Transmitters/Eject), never straight into another
	furnace or machine.

	Inserting (`insert`, `room`) follows Forge's ItemHandlerHelper.insertItemStacked, as Mekanism's
	transporters insert: first it tops up stacks of the same item, wear and data (Menu.stacksMatch)
	in slot order, then it fills empty slots in order, never beyond the item's max stack (at most 64,
	a container's limit). (Minecraft's hopper goes slot by slot instead, merging or filling as it
	meets them, and so does a furnace here: its input before its fuel, above.)

	Extracting is Mekanism's TransitRequest: `available` lists the item types that may leave
	through a face with the total of each over its slots, and `extract` takes up to n of one type
	from those slots in order (`results` and `takeResults` the same over the ejected slots). A
	transporter carries at most one stack, so they never take more than the item's max stack
	(tools one at a time).

	Everything is pure. Slots come in as `{ [slot]: Stack? }` and new tables come out: an input is
	never changed and a changed slot gets a new stack table (as in Inventory/Menu), so the server
	simulates (finds where an item can go) with the same calls it applies. Stacks keep their wear
	and item data in and out (a tank with water stays one); different data never merges.
]]

local Blocks = require(script.Parent.Parent.Blocks)
local Items = require(script.Parent.Parent.Items)
local Machines = require(script.Parent.Parent.Machines)
local Smelting = require(script.Parent.Parent.Crafting.Smelting)
local Menu = require(script.Parent.Parent.Inventory.Menu)
local Types = require(script.Parent.Parent.Inventory.Types)

type Stack = Items.Stack
export type Slots = { [number]: Stack? }

local Inventories = {}

-- Minecraft's furnace slots (1 input, 2 fuel, 3 output).
local INPUT, FUEL, OUTPUT = Types.FURNACE_INPUT, Types.FURNACE_FUEL, Types.FURNACE_OUTPUT
local stacksMatch = Menu.stacksMatch

-- A furnace's slots, the same through every face: in (the input first), out (the results
-- first) and pushed out on its own.
local FURNACE_INSERT: { number } = table.freeze({ INPUT, FUEL })
local FURNACE_EXTRACT: { number } = table.freeze({ OUTPUT, FUEL })
local FURNACE_EJECT: { number } = table.freeze({ OUTPUT })
local NO_SLOTS: { number } = table.freeze({})

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

-- A tool's wear as kept in a stack (a positive whole number, else nil), and a new stack with its
-- wear and data (nil for a count below 1).
local cleanDamage = Items.cleanDamage
local make = Items.newStack

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

--[[
	Is `block` a machine with item slots transporters reach through some face? (A Solar Panel's
	only slots are its upgrade slots, which they never reach: no transporter connects to it. Asked
	each time: tests bind machines at run time.)
]]
local function isMachine(block: number): boolean
	if not Machines.isMachine(block) or Machines.containerSize(block) <= 0 then
		return false
	end
	for face = 0, 5 do
		if #Machines.insertSlots(block, face) > 0 or #Machines.extractSlots(block, face) > 0 then
			return true
		end
	end
	return false
end

-- The most of `item` `slot` of `block` holds (a machine's slot may hold fewer).
local function slotLimit(block: number, slot: number, item: number): number
	if Machines.isMachine(block) then
		return Machines.slotLimit(block, slot, item)
	end
	return slotMax(item)
end

-- Does `block` keep items transporters reach (a chest, a furnace, a machine with such slots)?
function Inventories.isInventory(block: number): boolean
	return kinds[block] ~= nil or isMachine(block)
end

--[[
	Is `block` a plain inventory: a chest or any other block with a `container`, but no furnace
	and no machine? Furnaces and machines push their results straight into these only (never
	into each other: no surprise chains, cobblestone to stone to smooth stone).
]]
function Inventories.isPlain(block: number): boolean
	return kinds[block] == "chest" and not Machines.isMachine(block)
end

-- The slots items may enter `block` by through `face`, in the order they are tried (do not
-- change the list). Empty for blocks without slots and bad faces.
function Inventories.insertSlots(block: number, face: number): { number }
	if Machines.isMachine(block) then
		return Machines.insertSlots(block, face)
	end
	local kind = kinds[block]
	if kind == nil or not isFace(face) then
		return NO_SLOTS
	elseif kind == "furnace" then
		return FURNACE_INSERT
	end
	return allSlots[block]
end

-- The slots items may be taken from through `face`, in order (do not change the list): a
-- chest's every slot, a furnace's output and fuel (only what no longer burns leaves the fuel), a
-- machine's what its kind lists (its outputs by default).
function Inventories.extractSlots(block: number, face: number): { number }
	if Machines.isMachine(block) then
		return Machines.extractSlots(block, face)
	end
	local kind = kinds[block]
	if kind == nil or not isFace(face) then
		return NO_SLOTS
	elseif kind == "furnace" then
		return FURNACE_EXTRACT
	end
	return allSlots[block]
end

--[[
	The slots `block` pushes out on its own, in order (do not change the list): a furnace's output,
	a machine's output slots (Mekanism's ejector); empty for anything else.
]]
function Inventories.ejectSlots(block: number): { number }
	if Machines.isMachine(block) then
		return Machines.outputSlots(block)
	elseif kinds[block] == "furnace" then
		return FURNACE_EJECT
	end
	return NO_SLOTS
end

-- Does `block` push results out on its own (a furnace, a machine with output slots)?
function Inventories.ejects(block: number): boolean
	return #Inventories.ejectSlots(block) > 0
end

-- The item rules of a slot the face reaches (canPlaceItem / canTakeItemThroughFace), for the
-- loops below, which only visit such slots. A furnace's: Mekanism's machine slots (the input
-- only what smelts, the fuel only what burns; out of the fuel only what no longer burns). A
-- machine's: its kind's (Machines.mayPlace, Machines.mayTake).
local function mayPlace(block: number, slot: number, item: number): boolean
	if Machines.isMachine(block) then
		return Machines.mayPlace(block, slot, item)
	elseif kinds[block] == "furnace" then
		if slot == INPUT then
			return Smelting.result(item) ~= nil
		elseif slot == FUEL then
			return Smelting.fuel(item) > 0
		end
		return false
	end
	return true
end

local function mayTake(block: number, slot: number, item: number): boolean
	if Machines.isMachine(block) then
		return Machines.mayTake(block, slot, item)
	elseif slot == FUEL and kinds[block] == "furnace" then
		return Smelting.fuel(item) <= 0
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
		and mayTake(block, slot, item)
end

--[[
	How many of `stack` would go into `slots` of `block` through `face` (0..stack.count), as
	`insert` would put them: room on stacks of the same item, wear and data, then empty slots that
	take it.
]]
function Inventories.room(block: number, face: number, slots: Slots, stack: Stack): number
	if not isStack(stack) then
		return 0
	end
	local item = stack.item
	local room = 0
	for _, slot in Inventories.insertSlots(block, face) do
		if mayPlace(block, slot, item) then
			local max = slotLimit(block, slot, item)
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
	all of it went in). Stacks of the same item, wear and data are topped up first, in slot order,
	then empty slots are filled in order; a furnace's slots are filled one after the other instead
	(the input, then the fuel).
]]
function Inventories.insert(block: number, face: number, slots: Slots, stack: Stack): (Slots, Stack?)
	local out = table.clone(slots)
	if not isStack(stack) then
		-- Nothing goes in: a stack of an unknown item is all left over.
		local some = type(stack.count) == "number" and stack.count >= 1
		return out, if some then make(stack.item, math.floor(stack.count), stack.damage, stack.data) else nil
	end
	local item, damage, data = stack.item, cleanDamage(stack.damage), stack.data
	local left = stack.count
	local order = Inventories.insertSlots(block, face)
	if kinds[block] == "furnace" and not Machines.isMachine(block) then
		-- A furnace fills its slots one after the other (Mekanism's machine slots, in order): logs
		-- go into the input as long as it takes them, and only then top up the fuel.
		for _, slot in order do
			if left < 1 then
				break
			end
			local current = out[slot]
			local max = slotLimit(block, slot, item)
			if mayPlace(block, slot, item) then
				if current == nil or current.count < 1 then
					local put = math.min(left, max)
					if put >= 1 then
						out[slot] = make(item, put, damage, data)
						left -= put
					end
				elseif current.count < max and stacksMatch(current, stack) then
					local put = math.min(left, max - current.count)
					out[slot] = make(item, current.count + put, damage, data)
					left -= put
				end
			end
		end
		return out, make(item, left, damage, data)
	end
	-- Top up matching stacks first...
	for _, slot in order do
		if left < 1 then
			break
		end
		local current = out[slot]
		local max = slotLimit(block, slot, item)
		if
			current ~= nil
			and current.count >= 1
			and current.count < max
			and stacksMatch(current, stack)
			and mayPlace(block, slot, item)
		then
			local put = math.min(left, max - current.count)
			out[slot] = make(item, current.count + put, damage, data)
			left -= put
		end
	end
	-- ...then fill empty slots.
	for _, slot in order do
		if left < 1 then
			break
		end
		local current = out[slot]
		local max = slotLimit(block, slot, item)
		if (current == nil or current.count < 1) and max > 0 and mayPlace(block, slot, item) then
			local put = math.min(left, max)
			out[slot] = make(item, put, damage, data)
			left -= put
		end
	end
	return out, make(item, left, damage, data)
end

-- The item types in `list` (slots of `block`) that may be taken, with their totals (`available`).
local function typesIn(block: number, list: { number }, slots: Slots): { Stack }
	local found: { Stack } = {}
	for _, slot in list do
		local current = slots[slot]
		if current ~= nil and isStack(current) and mayTake(block, slot, current.item) then
			local merged = false
			for _, entry in found do
				if stacksMatch(entry, current) then
					entry.count += current.count
					merged = true
					break
				end
			end
			if not merged then
				table.insert(found, Items.copyStack(current) :: Stack)
			end
		end
	end
	return found
end

-- Takes up to `count` like `match` (nil: the first of `typesIn`) out of `list` (`extract`).
local function takeFrom(block: number, list: { number }, slots: Slots, count: number, match: Stack?): (Slots, Stack?)
	local out = table.clone(slots)
	local wanted = match or typesIn(block, list, slots)[1]
	-- (NaN fails `count >= 1`.)
	if wanted == nil or not Items.isValid(wanted.item) or type(count) ~= "number" or not (count >= 1) then
		return out, nil
	end
	local item = wanted.item
	local left = math.min(math.floor(count), slotMax(item))
	local taken = 0
	for _, slot in list do
		if left < 1 then
			break
		end
		local current = out[slot]
		if current ~= nil and isStack(current) and stacksMatch(current, wanted) and mayTake(block, slot, item) then
			local take = math.min(left, current.count)
			out[slot] = make(item, current.count - take, current.damage, current.data)
			left -= take
			taken += take
		end
	end
	return out, make(item, taken, wanted.damage, wanted.data)
end

--[[
	The item types (item, wear and data) that may be taken out of `slots` of `block` through
	`face`, in the order of their first slot, each with its total count over all those slots (which
	may be more than a stack).
	Mekanism's TransitRequest: a transporter looks for somewhere to send each type, in this order,
	before it takes anything.
]]
function Inventories.available(block: number, face: number, slots: Slots): { Stack }
	return typesIn(block, Inventories.extractSlots(block, face), slots)
end

--[[
	Takes up to `count` items like `match` (the same item, wear and data; nil: the first type
	`available` lists) out of `slots` of `block` through `face`, from its slots in order: the new
	slots and the stack taken (nil: nothing). Never more than the item's max stack.
]]
function Inventories.extract(block: number, face: number, slots: Slots, count: number, match: Stack?): (Slots, Stack?)
	return takeFrom(block, Inventories.extractSlots(block, face), slots, count, match)
end

-- `available` over the slots `block` pushes out on its own (`ejectSlots`): its results.
function Inventories.results(block: number, slots: Slots): { Stack }
	return typesIn(block, Inventories.ejectSlots(block), slots)
end

-- `extract` from the slots `block` pushes out on its own (`ejectSlots`): its results.
function Inventories.takeResults(block: number, slots: Slots, count: number, match: Stack?): (Slots, Stack?)
	return takeFrom(block, Inventories.ejectSlots(block), slots, count, match)
end

return Inventories
