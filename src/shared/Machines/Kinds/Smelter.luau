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
	  1 input   what smelts (Mekanism's input slots take only valid recipe inputs), put in by
	            hand, shift-click (anything that smelts goes here) and transporters through any
	            face
	  2 output  only taken from: by hand, shift-click and transporters through any face; and it
	            pushes its results out on its own every 10 ticks into the transporters and chests
	            around it (Mekanism's ejector; server Transmitters/Transport and Eject)
	  3 speed   up to 8 Speed Upgrades, at (8, 53) on the panel's lower left
	  4 energy  up to 8 Energy Upgrades, at (26, 53) next to it; both by hand and shift-click only
	            (Machines/Upgrades: no transporter face reaches them), clear of the status line,
	            the row and the energy bar
	Blocks have no facing, so Mekanism's configurable sides become the same on every face: ore in,
	results out (Core's defaults), the rules furnaces follow too (Transmitters/Inventories).

	Every tick `settings` works out Mekanism's upgrade maths from the cards installed: the ticks an
	item takes (200 x 10^(-speed/8), truncated: 149 with one card, 20 with 8), the energy a tick of
	work uses (50 x 10^((2 speed - energy)/8)) and the capacity (20 000 x 10^(energy/8)). Taking
	cards out applies at once: progress past the new ticks finishes on the next tick, and energy
	over a smaller capacity is lost (Mekanism's setMaxEnergy).

	Data after the header (Shared/Machines):
	  progress       ticks worked on the item in the input (the arrow: progress / ticksRequired)
	  ticksRequired  ticks an item takes (200; fewer with Speed Upgrades)
	  energyPerTick  J a tick of work uses (50; more with Speed, less with Energy Upgrades)
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
	Only its energy is kept in its item when broken (placed again, it holds at most its capacity
	without Energy Upgrades); its slots drop, upgrade cards included, so the progress goes.

	Its panel: the input, Minecraft's arrow and the output in the furnace's result frame in a row,
	the status line above them, the upgrade slots below on the left and the energy bar. JEI lists
	it as a smelting catalyst.
]]

local Core = require(script.Parent.Parent.Core)
local Upgrades = require(script.Parent.Parent.Upgrades)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container
type Stack = Items.Stack

-- Mekanism's Energized Smelter: ticks an item takes and J a tick of work uses.
local BASE_TICKS = 200
local BASE_ENERGY_PER_TICK = 50

-- Slots.
local INPUT, OUTPUT, SPEED, ENERGY = 1, 2, 3, 4

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local IDLE, NO_POWER, OUTPUT_FULL = 0, 1, 2

-- Ticks a stopped machine keeps showing it works after its last stop (Mekanism's
-- blockDeactivationDelay, 60).
local DEACTIVATION_DELAY = 60

local function smelts(item: number): boolean
	return Smelting.result(item) ~= nil
end

--[[
	Ticks an item takes, J a tick of work uses and the capacity, now: the base values changed by
	the upgrade cards in slots 3 and 4 (Mekanism's maths, Machines/Upgrades).
]]
local function settings(container: Container, ctx: Core.TickContext): (number, number, number)
	local speed, energy = Upgrades.counts(container, SPEED, ENERGY)
	return Upgrades.ticks(BASE_TICKS, speed),
		Upgrades.energyPerTick(BASE_ENERGY_PER_TICK, speed, energy),
		Upgrades.capacity(ctx.energy.capacity, energy)
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
	Upgrades.setCapacity(container, capacity)

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

-- The input, then the output in Minecraft's result frame, in a row with the arrow between them;
-- the upgrade slots below on the left. Transporters reach the input and the output through every
-- face (Core's defaults: inputs take, outputs give).
local SLOTS: { Core.SlotSpec } = {
	{ x = 56, y = 35, accepts = smelts },
	{ x = 116, y = 35, output = true, big = true },
}
for _, slot in Upgrades.slots(8, 53) do
	table.insert(SLOTS, slot)
end
assert(#SLOTS == ENERGY, "the Electric Furnace's upgrade slots are 3 and 4")

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
