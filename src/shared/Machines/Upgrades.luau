--!strict
--[[
	Mekanism's upgrade cards (its Upgrade enum and MekanismUtils): the Speed Upgrade and the Energy
	Upgrade (ItemList `SpeedUpgrade`, `EnergyUpgrade`), the slots machines take them in and the
	maths of what they do. Pure; kind modules require it next to Machines/Core.

	A machine that takes upgrades has a slot for each kind of card (`slots`): it holds up to MAX
	(8, Mekanism's Upgrade.getMax) cards of its kind and nothing else, filled by hand or by
	shift-click. Transporters never reach it (Mekanism's upgrades sit in a tab of their own, out of
	its side configuration), and the card's outline shows while it is empty. What a machine does
	with `speed` and `energy` cards installed is Mekanism's maths, with MULTIPLIER its
	maxUpgradeMultiplier (10), so 8 cards change a number tenfold:

	  ticks          base x 10^(-speed/8), truncated (MekanismUtils.getTicks): an item's 200 ticks
	                 become 149 with one card and 20 with 8
	  energyPerTick  base x 10^((2 speed - energy)/8) (getEnergyPerTick): speed costs energy, and
	                 energy cards win it back (8 speed and 8 energy cards: 10 times the base)
	  capacity       base x 10^(energy/8) (getMaxEnergy)
	  production     base x 10^(speed/8): the Solar Panel's (Mekanism's solar generators take no
	                 upgrades; here Speed Upgrades raise what one makes as they speed up a machine's
	                 work, tenfold with 8, and Energy Upgrades its store)

	Counts come from the slots' stacks (`installed`): only the slot's own card counts, at most MAX,
	whatever a stack from elsewhere says.
]]

local Items = require(script.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Inventory.Types)
local Core = require(script.Parent.Core)

type Stack = Items.Stack
type Container = Types.Container

local Upgrades = {}

-- Cards of a kind a machine takes at most (Mekanism's Upgrade.SPEED / ENERGY getMax).
Upgrades.MAX = 8
-- Mekanism's maxUpgradeMultiplier: what MAX cards multiply a number by.
Upgrades.MULTIPLIER = 10

-- The cards' items.
Upgrades.SPEED = Items.id.SpeedUpgrade
Upgrades.ENERGY = Items.id.EnergyUpgrade

-- Outlines of the cards' symbols, shown in their empty slots (Core SlotSpec `ghost`): two
-- chevrons for speed, a bolt for energy.
Upgrades.SPEED_GHOST = table.freeze({
	"................",
	"................",
	"................",
	"..GG....GG......",
	"...GG....GG.....",
	"....GG....GG....",
	".....GG....GG...",
	"......GG....GG..",
	"......GG....GG..",
	".....GG....GG...",
	"....GG....GG....",
	"...GG....GG.....",
	"..GG....GG......",
	"................",
	"................",
	"................",
})
Upgrades.ENERGY_GHOST = table.freeze({
	"................",
	".........GGGG...",
	"........GGGG....",
	".......GGGG.....",
	"......GGGG......",
	".....GGGG.......",
	"....GGGGGGGGG...",
	"...GGGGGGGGG....",
	"........GGGG....",
	".......GGGG.....",
	"......GGGG......",
	".....GGGG.......",
	"....GGG.........",
	"...GG...........",
	"................",
	"................",
})

function Upgrades.isSpeed(item: number): boolean
	return item == Upgrades.SPEED
end

function Upgrades.isEnergy(item: number): boolean
	return item == Upgrades.ENERGY
end

-- Is `item` an upgrade card?
function Upgrades.isUpgrade(item: number): boolean
	return item == Upgrades.SPEED or item == Upgrades.ENERGY
end

-- How many `card`s `stack` installs: its whole count, 0..MAX (0 for another item or nothing).
function Upgrades.installed(stack: Stack?, card: number): number
	if stack == nil or stack.item ~= card then
		return 0
	end
	local count = stack.count
	if type(count) ~= "number" or count ~= count then
		return 0
	end
	return math.clamp(math.floor(count), 0, Upgrades.MAX)
end

-- The Speed and Energy Upgrades installed in a machine's `speedSlot` and `energySlot`.
function Upgrades.counts(container: Container, speedSlot: number, energySlot: number): (number, number)
	local slots = container.slots
	return Upgrades.installed(slots[speedSlot], Upgrades.SPEED), Upgrades.installed(slots[energySlot], Upgrades.ENERGY)
end

-- Mekanism's fractionUpgrades: the share of the most cards installed (0..1).
local function fraction(cards: number): number
	return math.clamp(cards, 0, Upgrades.MAX) / Upgrades.MAX
end

-- Ticks an operation of `base` ticks takes with `speed` cards (MekanismUtils.getTicks; at least 1).
function Upgrades.ticks(base: number, speed: number): number
	return math.max(1, math.floor(base * Upgrades.MULTIPLIER ^ -fraction(speed)))
end

-- J a tick of work uses with `speed` and `energy` cards (MekanismUtils.getEnergyPerTick).
function Upgrades.energyPerTick(base: number, speed: number, energy: number): number
	return base * Upgrades.MULTIPLIER ^ (2 * fraction(speed) - fraction(energy))
end

-- J a machine of `base` J holds with `energy` cards (MekanismUtils.getMaxEnergy).
function Upgrades.capacity(base: number, energy: number): number
	return base * Upgrades.MULTIPLIER ^ fraction(energy)
end

-- J/t a generator making `base` J/t makes with `speed` cards (the Solar Panel; see the header).
function Upgrades.production(base: number, speed: number): number
	return base * Upgrades.MULTIPLIER ^ fraction(speed)
end

--[[
	Sets a machine's capacity (what its Energy Upgrades make it) and cuts what it holds to it at
	once, as Mekanism's setMaxEnergy does: energy over a smaller store is lost before the tick's
	work, not after it.
]]
function Upgrades.setCapacity(container: Container, capacity: number)
	Core.set(container, "capacity", capacity)
	if Core.energy(container) > capacity then
		Core.set(container, "energy", Core.quantise(capacity))
	end
end

--[[
	A machine's upgrade slots for its kind's `slots`: the Speed Upgrade's with its item at (x, y),
	the Energy Upgrade's one slot to the right (x + 18, y), each holding MAX cards of its kind,
	out of the transporters' reach, with the card's outline while empty.
]]
function Upgrades.slots(x: number, y: number): { Core.SlotSpec }
	return {
		{ x = x, y = y, accepts = Upgrades.isSpeed, limit = Upgrades.MAX, insert = {}, ghost = Upgrades.SPEED_GHOST },
		{
			x = x + 18,
			y = y,
			accepts = Upgrades.isEnergy,
			limit = Upgrades.MAX,
			insert = {},
			ghost = Upgrades.ENERGY_GHOST,
		},
	}
end

return table.freeze(Upgrades)
