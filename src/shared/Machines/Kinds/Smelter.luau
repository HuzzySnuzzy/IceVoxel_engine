--!strict
--[[
	Mekanism's Energized Smelter (kind "smelter"), named the Electric Furnace: BlockList
	`ElectricFurnace`, `energy = { capacity = 20 000 J, input = 20 000 J/t }` (Mekanism's storage;
	a network may fill it in a single tick, as Mekanism's machine energy containers take any
	amount: `rates` gives its capacity as its input rate).

	It smelts what a furnace smelts (Crafting/Smelting.result) with electricity instead of fuel.
	Every tick it works uses `energyPerTick` J (Mekanism's 50 J/t) and moves the progress on by
	one; after `ticksRequired` ticks (Mekanism's 200, a furnace's 10 seconds) one input item
	becomes the recipe's result in the output: 10 kJ an item. It works only with a whole tick's
	energy stored: without it the progress stops where it is and goes on when energy comes, as it
	does while the output has no room for the result (Mekanism pauses on both). Taking the input
	away, or putting another item in its place, starts the progress over (Mekanism's recipe
	cache; Minecraft's furnace).

	Slots (Mekanism's are input, output and an energy slot, with upgrades in a tab of their own):
	  1 input   what smelts, put in by hand, shift-click (anything that smelts goes here) and
	            transporters through the top and the four sides
	  2 output  only taken from: by hand, shift-click and transporters through the bottom
	            (Minecraft's furnace's faces: in at the top, out at the bottom; blocks have no
	            facing, so Mekanism's configurable sides become fixed ones)
	Room is left for Mekanism's upgrade cards: slots 3 (speed) and 4 (energy), at (8, 53) and
	(26, 53) on the panel's lower left, clear of the status line, the row and the energy bar; they
	need no data beyond what is here. `settings` is where they will set the ticks an item takes,
	the energy a tick uses and the capacity (Mekanism's upgrade maths); without upgrades it gives
	the base values.

	Data after the header (Shared/Machines):
	  progress       ticks worked on the item in the input (the arrow: progress / ticksRequired)
	  ticksRequired  ticks an item takes (200)
	  energyPerTick  J a tick of work uses (50)
	  smelting       the item being smelted (0: none): another item starts over
	  state          why it is not working (the state code WAILA gets): IDLE (nothing to smelt),
	                 NO_POWER (less than a tick's energy) or OUTPUT_FULL (no room for the result)
	  activeDelay    ticks ACTIVE is held on through stops (Mekanism's updateDelay, below)
	RATE is minus the energy it used this tick (-50 while working, else 0): whether it works now,
	which its status reads (WAILA, the panel): "Using 50 J/t", "No power", "Output full" or "Idle".
	ACTIVE is what the block shows (its glowing chamber, WAILA's F3 line), Mekanism's client active
	state (TileEntityMekanism.setActive): on as soon as it works; off at once when it stops, unless
	it stopped less than DEACTIVATION_DELAY ticks before, in which case it stays on until it has not
	worked for that long. So a furnace on too little power (working every other tick) glows
	steadily instead of blinking, and one that finishes goes dark at once.
	Only its energy is kept in its item when broken; its slots drop, so the progress goes.

	Its panel: the input, Minecraft's arrow and the output in the furnace's result frame in a row,
	the status line above them and the energy bar. JEI lists it as a smelting catalyst.
]]

local Core = require(script.Parent.Parent.Core)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container
type Stack = Items.Stack

-- Mekanism's Energized Smelter: ticks an item takes and J a tick of work uses.
local BASE_TICKS = 200
local BASE_ENERGY_PER_TICK = 50

-- Slots.
local INPUT, OUTPUT = 1, 2
-- Faces (Transmitters.SIDES): Down, Up, North, South, West, East.
local DOWN = 0
local TOP_AND_SIDES = { 1, 2, 3, 4, 5 }

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local IDLE, NO_POWER, OUTPUT_FULL = 0, 1, 2

-- Ticks a stopped machine keeps showing it works after its last stop (Mekanism's
-- blockDeactivationDelay, 60).
local DEACTIVATION_DELAY = 60

local function smelts(item: number): boolean
	return Smelting.result(item) ~= nil
end

--[[
	Ticks an item takes, J a tick of work uses and the capacity, now. The base values; upgrade
	cards (slots 3 and 4) will change them here with Mekanism's maths.
]]
local function settings(_container: Container, ctx: Core.TickContext): (number, number, number)
	return BASE_TICKS, BASE_ENERGY_PER_TICK, ctx.energy.capacity
end

-- Is there room in the output for `result` (the same item, wear and data, within its limit)?
local function fits(container: Container, result: Stack): boolean
	local limit = Core.slotLimit(container.block, OUTPUT, result.item)
	local output = container.slots[OUTPUT]
	if output == nil then
		return result.count <= limit
	end
	return Items.stacksMatch(output, result) and output.count + result.count <= limit
end

--[[
	Sets what the block shows (ACTIVE) from whether it works this tick (`working`) and worked last
	tick (`wasWorking`): Mekanism's TileEntityMekanism.setActive and its updateDelay countdown. On
	at once; off at once unless the delay (started by every stop) is still running, then off when
	it runs out with the machine still stopped.
]]
local function showActive(container: Container, wasWorking: boolean, working: boolean)
	local shown = Core.get(container, "active") ~= 0
	-- (Data from elsewhere: a whole number of ticks, at most the delay.)
	local delay = math.clamp(math.floor(Core.get(container, "activeDelay")), 0, DEACTIVATION_DELAY)
	if delay > 0 then
		delay -= 1
		if delay == 0 then
			shown = wasWorking
		end
	end
	if working ~= wasWorking and shown ~= working then
		if working then
			shown = true
		else
			if delay == 0 then
				shown = false
			end
			delay = DEACTIVATION_DELAY
		end
	end
	Core.set(container, "active", if shown then 1 else 0)
	Core.set(container, "activeDelay", delay)
end

local function tick(container: Container, ctx: Core.TickContext)
	-- (RATE still holds last tick's: below 0 when it worked.)
	local wasWorking = Core.get(container, "rate") < 0
	local ticks, energyPerTick, capacity = settings(container, ctx)
	Core.set(container, "ticksRequired", ticks)
	Core.set(container, "energyPerTick", energyPerTick)
	Core.set(container, "capacity", capacity)

	local slots = container.slots
	local input = slots[INPUT]
	local item = if input then input.item else 0
	-- (Never past the end, whatever the data says: a full arrow finishes on the next tick.)
	local progress = math.clamp(math.floor(Core.get(container, "progress")), 0, ticks)
	if item ~= Core.get(container, "smelting") then
		-- Another item (or none): its smelting starts over.
		Core.set(container, "smelting", item)
		progress = 0
	end

	local result = if input then Smelting.result(input.item) else nil
	local state, working = IDLE, false
	if input == nil or result == nil then
		-- Nothing to smelt (Mekanism resets the progress when the input runs out).
		progress = 0
	elseif not fits(container, result) then
		state = OUTPUT_FULL
	elseif not Core.use(container, energyPerTick) then
		state = NO_POWER
	else
		working = true
		progress += 1
		if progress >= ticks then
			progress = 0
			local output = slots[OUTPUT]
			slots[OUTPUT] = if output
				then Items.withCount(output, output.count + result.count)
				else Items.newStack(result.item, result.count)
			-- (What is left keeps its wear and data.)
			slots[INPUT] = Items.withCount(input, input.count - 1)
		end
	end
	Core.set(container, "progress", progress)
	Core.set(container, "state", state)
	Core.set(container, "rate", if working then -Core.quantiseUp(energyPerTick) else 0)
	showActive(container, wasWorking, working)
end

-- The input, then the output in Minecraft's result frame, in a row with the arrow between them.
local SLOTS: { Core.SlotSpec } = {
	{ x = 56, y = 35, accepts = smelts, insert = TOP_AND_SIDES },
	{ x = 116, y = 35, output = true, big = true, extract = { DOWN } },
}

return Core.define("smelter", {
	slots = SLOTS,
	fields = { "progress", "ticksRequired", "energyPerTick", "smelting", "state", "activeDelay" },
	state = "state",
	panel = {
		progress = { x = 79, y = 34, value = "progress", total = "ticksRequired" },
		-- (Above the row, so the lower left stays free for the upgrade slots.)
		status = { x = 8, y = 20 },
	},
	tick = tick,
	-- Mekanism's machine energy containers take any amount: up to its capacity in a tick.
	rates = function(container: Container, _energy: Core.EnergySpec): (number, number)
		return Core.capacity(container), 0
	end,
	status = function(view: Core.View): string?
		if view.rate < 0 then
			return `Using {Items.formatEnergy(-view.rate)}/t`
		elseif view.state == NO_POWER then
			return "No power"
		elseif view.state == OUTPUT_FULL then
			return "Output full"
		end
		return "Idle"
	end,
})
