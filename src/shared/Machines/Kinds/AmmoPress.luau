--!strict
--[[
	The Ammo Press (kind "press"; BlockList `AmmoPress`, `energy = { capacity = 20 kJ, input =
	20 kJ/t }`, Config.AmmoPress): an Iron Ingot and a Gunpowder pressed into rounds of the calibre
	its button picks, so turrets (and guns) need not live on loot alone: one operation makes 16
	9mm, 10 5.56 or 5 .308 rounds in 200 ticks at 50 J a tick (10 kJ: an Electric Furnace's item),
	faster with Speed Upgrades (Mekanism's maths, Machines/Upgrades). Gunpowder needs the
	Demolition skill, so the press opens nothing new on its own.

	It works as the Electric Furnace does (Kinds/Smelter): every tick it works uses
	`energyPerTick` J and moves the progress on by one; after `ticksRequired` ticks one Iron Ingot
	and one Gunpowder become the calibre's rounds in the output. It works only with a whole tick's
	energy stored and room in the output for all of an operation's rounds (the same round, within
	its stack); without either the progress waits where it is and goes on when they come
	(Mekanism pauses on both). Taking either input away starts the progress over (Mekanism resets
	it when the input runs out). Every calibre costs the same, so the Calibre button keeps the
	progress: what comes out is the calibre chosen when the operation finishes.

	Every tick `settings` works out Mekanism's upgrade maths from the cards installed, as the
	Electric Furnace's: the ticks an operation takes (Config.AmmoPress.Ticks x 10^(-speed/8),
	truncated: 149 with one card, 20 with 8), the energy a tick of work uses (Joules x
	10^((2 speed - energy)/8)) and the capacity (the block's store x 10^(energy/8)). Taking cards
	out applies at once (energy over a smaller capacity is lost: Mekanism's setMaxEnergy). A
	change of `ticksRequired` keeps the share of the operation done, not the ticks worked
	(`Upgrades.rescale`: the progress x new / old ticks, rounded down), so a card swap never skips
	work.

	With Config.AmmoPress.Enabled false (read every tick) it is inert: it uses nothing, makes
	nothing, keeps its progress and says "Idle" (its recipe is left out then: Crafting/Recipes,
	Progression/Ages).

	Slots (frozen):
	  1 ingot      Iron Ingots only: by hand, shift-click and transporters through any face
	  2 gunpowder  Gunpowder only, the same way
	  3 output     the rounds (Minecraft's result frame at (116, 35)): taken by hand, shift-click
	               and transporters, and pushed out on its own every 10 ticks into the chests
	               next to it (Mekanism's ejector: server Transmitters/Eject and Transport)
	  4 speed      up to 8 Speed Upgrades, at (8, 53)
	  5 energy     up to 8 Energy Upgrades, at (26, 53)
	Data after the header (Shared/Machines), frozen:
	   7 progress       ticks worked on the operation (the arrow: progress / ticksRequired)
	   8 ticksRequired  ticks an operation takes (Config.AmmoPress.Ticks; fewer with cards)
	   9 energyPerTick  J a tick of work uses (Config.AmmoPress.Joules; changed by the cards)
	  10 calibre        the calibre pressed: an index into Config.AmmoPress.Calibres (1 9mm, 2
	                    5.56, 3 .308; a fresh press's 1), which the Calibre button cycles; kept
	                    in the item
	  11 state          why it is not working (the status line, WAILA): IDLE (nothing in it, or
	                    switched off), NO_POWER (less than a tick's energy), OUTPUT_FULL (no room
	                    for the rounds), NO_INPUT (an ingot without gunpowder, or the other way
	                    round)
	  12 activeDelay    Mekanism's deactivation delay (Machines.showActive: ACTIVE while it works,
	                    its window glows and it stamps)
	RATE is minus the J it used this tick. It takes as much energy as its store holds in a tick
	(`rates`: its capacity, as the Electric Furnace).

	Its panel: the ingot and the gunpowder, the progress arrow and the output in a row, the status
	line, the Calibre button and a line naming what one operation makes ("16 9mm Rounds"), the
	upgrade slots and the energy bar. JEI's "Pressing" (an Iron Ingot and a Gunpowder into rounds,
	the Ammo Press the catalyst) reads `info`: ticks, joules, capacity and each round's count by
	its item name.
]]

local Core = require(script.Parent.Parent.Core)
local Upgrades = require(script.Parent.Parent.Upgrades)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local Weapons = require(script.Parent.Parent.Parent.Weapons)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local PRESS = Config.AmmoPress

-- Slots.
local INGOT, GUNPOWDER, OUTPUT, SPEED, ENERGY = 1, 2, 3, 4, 5

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT = 0, 1, 2, 3

-- The Calibre button's id, and the calibre's data index (its fourth field).
local CALIBRE_BUTTON = 0
local CALIBRE = Core.HEADER + 4

local IRON, POWDER = Items.id.IronIngot, Items.id.Gunpowder

-- What each calibre choice makes: the round's item, how many, its calibre's name, and an
-- operation's result as a stack (read only: the output gets a new one).
type Calibre = { ammo: number, count: number, calibre: string, result: Items.Stack }
local CALIBRES: { Calibre } = {}
for index, entry in PRESS.Calibres do
	local item = rawget(Items.id :: any, entry.ammo)
	local round = Weapons.ammo(item)
	assert(round and entry.count >= 1, `AmmoPress: calibre {index} needs a round and a count`)
	CALIBRES[index] = table.freeze({
		ammo = item :: number,
		count = entry.count,
		calibre = round.calibre,
		result = table.freeze({ item = item :: number, count = entry.count }) :: Items.Stack,
	})
end

-- The calibre choice of a press's data (whole, 1..#CALIBRES; anything else the first).
local function calibreOf(value: number): number
	if value ~= value or value ~= math.floor(value) or value < 1 or value > #CALIBRES then
		return 1
	end
	return value
end

local SLOTS: { Core.SlotSpec } = {
	{
		x = 38,
		y = 35,
		accepts = function(item: number): boolean
			return item == IRON
		end,
	},
	{
		x = 56,
		y = 35,
		accepts = function(item: number): boolean
			return item == POWDER
		end,
	},
	{ x = 116, y = 35, output = true, big = true },
}
for _, slot in Upgrades.slots(8, 53) do
	table.insert(SLOTS, slot)
end
assert(#SLOTS == ENERGY and INGOT == 1 and GUNPOWDER == 2 and OUTPUT == 3 and SPEED == 4, "the Ammo Press's slots")

--[[
	Ticks an operation takes, J a tick of work uses and the capacity, now: Config.AmmoPress's
	numbers and the block's store changed by the cards in slots 4 and 5 (Mekanism's maths,
	Machines/Upgrades).
]]
local function settings(container: Container, ctx: Core.TickContext): (number, number, number)
	local speed, energy = Upgrades.counts(container, SPEED, ENERGY)
	return Upgrades.ticks(PRESS.Ticks, speed),
		Upgrades.energyPerTick(PRESS.Joules, speed, energy),
		Upgrades.capacity(ctx.energy.capacity, energy)
end

-- Does `slot` hold at least one `item` (data from elsewhere may put anything anywhere)?
local function holds(container: Container, slot: number, item: number): boolean
	local stack = container.slots[slot]
	return stack ~= nil and stack.item == item and type(stack.count) == "number" and stack.count >= 1
end

-- Is there room in the output for all of `calibre`'s rounds (the same round, within its limit)?
local function fits(container: Container, calibre: Calibre): boolean
	local limit = Core.slotLimit(container.block, OUTPUT, calibre.ammo)
	local output = container.slots[OUTPUT]
	if output == nil then
		return calibre.count <= limit
	end
	return Items.stacksMatch(output, calibre.result) and output.count + calibre.count <= limit
end

local function tick(container: Container, ctx: Core.TickContext)
	-- (RATE still holds last tick's: below 0 when it worked.)
	local wasWorking = Core.get(container, "rate") < 0
	if not PRESS.Enabled then
		-- Switched off: inert, nothing used or made, the progress left as it is.
		Core.set(container, "state", IDLE)
		Core.set(container, "rate", 0)
		Core.showActive(container, wasWorking, false)
		return
	end
	local ticks, energyPerTick, capacity = settings(container, ctx)
	-- (Cards in or out keep the share of the operation done, rounded down: no work skipped.)
	local progress = Upgrades.rescale(Core.get(container, "progress"), Core.get(container, "ticksRequired"), ticks)
	Core.set(container, "ticksRequired", ticks)
	Core.set(container, "energyPerTick", energyPerTick)
	Upgrades.setCapacity(container, capacity)
	-- (A calibre from elsewhere reads as the first, and is kept so.)
	local choice = calibreOf(Core.get(container, "calibre"))
	Core.set(container, "calibre", choice)
	local calibre = CALIBRES[choice]

	local slots = container.slots
	local hasIngot, hasPowder = holds(container, INGOT, IRON), holds(container, GUNPOWDER, POWDER)
	-- (Never past the end, whatever the data says: a full arrow finishes on the next tick.)
	progress = math.clamp(math.floor(progress), 0, ticks)
	local state, working = IDLE, false
	if not (hasIngot and hasPowder) then
		-- Nothing to press: idle when empty, waiting for the other input with one of them.
		progress = 0
		state = if hasIngot or hasPowder then NO_INPUT else IDLE
	elseif not fits(container, calibre) then
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
				then Items.withCount(output, output.count + calibre.count)
				else Items.newStack(calibre.ammo, calibre.count)
			-- (What is left of each input keeps its wear and data.)
			local ingot, powder = slots[INGOT] :: Items.Stack, slots[GUNPOWDER] :: Items.Stack
			slots[INGOT] = Items.withCount(ingot, ingot.count - 1)
			slots[GUNPOWDER] = Items.withCount(powder, powder.count - 1)
		end
	end
	Core.set(container, "progress", progress)
	Core.set(container, "state", state)
	Core.set(container, "rate", if working then -Core.quantiseUp(energyPerTick) else 0)
	-- (Held on through short stops: Mekanism's blockDeactivationDelay, Shared/Machines.)
	Core.showActive(container, wasWorking, working)
end

local info: { [string]: number } = { ticks = PRESS.Ticks, joules = PRESS.Joules, capacity = PRESS.Capacity }
for _, entry in PRESS.Calibres do
	info[entry.ammo] = entry.count
end

local kind = Core.define("press", {
	slots = SLOTS,
	fields = { "progress", "ticksRequired", "energyPerTick", "calibre", "state", "activeDelay" },
	keep = { "calibre" },
	defaults = { calibre = 1 },
	state = "state",
	panel = {
		progress = { x = 79, y = 34, value = "progress", total = "ticksRequired" },
		status = { x = 8, y = 20 },
		lines = { x = 100, y = 60 },
	},
	buttons = {
		{ id = CALIBRE_BUTTON, x = 52, y = 56, w = 44, h = 14, label = "Calibre" },
	},
	onButton = function(container: Container, button: number)
		if button == CALIBRE_BUTTON then
			Core.set(container, "calibre", calibreOf(Core.get(container, "calibre")) % #CALIBRES + 1)
		end
	end,
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
		elseif view.state == NO_INPUT then
			return "No input"
		end
		return "Idle"
	end,
	-- (The calibre is the window's: no record carries it.)
	lines = function(_view: Core.View, data: { number }?): { string }
		local value = if data then data[CALIBRE] else nil
		if type(value) ~= "number" then
			return {}
		end
		local calibre = CALIBRES[calibreOf(value)]
		return { `{calibre.count} {Items.displayName(calibre.ammo)}` }
	end,
	info = info,
})
assert(kind.index.calibre == CALIBRE, "the Ammo Press's calibre is its fourth field")

return kind
