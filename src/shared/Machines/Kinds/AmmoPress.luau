--!strict
--[[
	The Ammo Press (kind "press"; BlockList `AmmoPress`, `energy = { capacity = 20 kJ, input =
	20 kJ/t }`, Config.AmmoPress): a Brass Ingot (the cases), a Lead Ingot (the bullets) and a
	Gunpowder pressed into rounds of the calibre its button picks, so turrets (and guns) need not
	live on loot alone: one operation makes 16 9mm, 10 5.56 or 5 .308 rounds in 200 ticks at 50 J
	a tick (10 kJ: an Electric Furnace's item), faster with Speed Upgrades (Mekanism's maths,
	Machines/Upgrades). Gunpowder needs the Demolition skill, so the press opens nothing new on its
	own.

	It works as the Electric Furnace does (Kinds/Smelter): every tick it works uses
	`energyPerTick` J and moves the progress on by one; after `ticksRequired` ticks one of each
	input becomes the calibre's rounds in the output. It works only with all three inputs, a whole
	tick's energy stored and room in the output for all of an operation's rounds (the same round,
	within its stack); without the energy or the room the progress waits where it is and goes on
	when they come (Mekanism pauses on both). Taking any input away starts the progress over
	(Mekanism resets it when the input runs out). Every calibre costs the same, so the Calibre
	button keeps the progress: what comes out is the calibre chosen when the operation finishes.

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

	Slots (frozen; 6 appended after the cards, so a press saved with five keeps every slot: a
	world save's container goes into the block's fresh six-slot container, slot by slot, Save/
	WorldSnapshot):
	  1 brass      Brass Ingots only: by hand, shift-click and transporters through any face (it
	               took Iron Ingots before lead and brass: an old press's stay there and press
	               nothing, NO_INPUT beside gunpowder, until a hand or a shift-click takes them
	               out; transporters take only the rounds)
	  2 gunpowder  Gunpowder only, the same way
	  3 output     the rounds (Minecraft's result frame at (116, 35)): taken by hand, shift-click
	               and transporters, and pushed out on its own every 10 ticks into the chests
	               next to it (Mekanism's ejector: server Transmitters/Eject and Transport)
	  4 speed      up to 8 Speed Upgrades, at (8, 53)
	  5 energy     up to 8 Energy Upgrades, at (26, 53)
	  6 lead       Lead Ingots only, the same way as the brass
	Data after the header (Shared/Machines), frozen:
	   7 progress       ticks worked on the operation (the arrow: progress / ticksRequired)
	   8 ticksRequired  ticks an operation takes (Config.AmmoPress.Ticks; fewer with cards)
	   9 energyPerTick  J a tick of work uses (Config.AmmoPress.Joules; changed by the cards)
	  10 calibre        the calibre pressed: an index into Config.AmmoPress.Calibres (1 9mm, 2
	                    5.56, 3 .308; a fresh press's 1), which the Calibre button cycles; kept
	                    in the item
	  11 state          why it is not working (the status line, WAILA): a code, IDLE (none of the
	                    three in it, or switched off), NO_POWER (less than a tick's energy),
	                    OUTPUT_FULL (no room for the rounds) or NO_INPUT (one or two of the three
	                    without the rest), plus with NO_INPUT 4 x the inputs missing (1 brass, 2
	                    lead, 4 gunpowder: Mekanism names the input a recipe lacks), so the status
	                    says "No lead" or "No brass or gunpowder" (a 3 saved before lead, or from
	                    elsewhere, says "No input" until the next tick)
	  12 activeDelay    Mekanism's deactivation delay (Machines.showActive: ACTIVE while it works,
	                    its window glows and it stamps)
	RATE is minus the J it used this tick. It takes as much energy as its store holds in a tick
	(`rates`: its capacity, as the Electric Furnace).

	Its panel: the brass, the lead and the gunpowder in a row (x 20, 38, 56: the cases, the bullets,
	the powder, as an operation reads), the progress arrow and the output, the status line, the
	Calibre button and a line naming what one operation makes ("16 9mm Rounds"), the upgrade slots
	and the energy bar. JEI's "Pressing" (a Brass Ingot, a Lead Ingot and a Gunpowder into rounds,
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

-- Slots (lead appended after the cards: the five before it are frozen).
local BRASS, GUNPOWDER, OUTPUT, SPEED, ENERGY, LEAD = 1, 2, 3, 4, 5, 6

-- State codes (the `state` field's code, state % CODES; Shared/Machines KindSpec `state`). With
-- NO_INPUT, CODES x the missing inputs' bits (INPUTS) go on top of it.
local IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT = 0, 1, 2, 3
local CODES = 4

-- The Calibre button's id, and the calibre's data index (its fourth field).
local CALIBRE_BUTTON = 0
local CALIBRE = Core.HEADER + 4

local BRASS_INGOT, LEAD_INGOT, POWDER = Items.id.BrassIngot, Items.id.LeadIngot, Items.id.Gunpowder

--[[
	The three inputs, one of each an operation, in the panel's order (the cases, the bullets, the
	powder): the slot, the item it takes, the bit it sets in a NO_INPUT state while missing and the
	word the status names it by.
]]
type Input = { slot: number, item: number, bit: number, word: string }
local INPUTS: { Input } = {
	{ slot = BRASS, item = BRASS_INGOT, bit = 1, word = "brass" },
	{ slot = LEAD, item = LEAD_INGOT, bit = 2, word = "lead" },
	{ slot = GUNPOWDER, item = POWDER, bit = 4, word = "gunpowder" },
}
-- (Every bit set: the most a state's missing part holds.)
local ALL_MISSING = 7

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

-- An input slot at (x, 35) taking only `item` (by hand, shift-click and transporters alike).
local function inputSlot(x: number, item: number): Core.SlotSpec
	return {
		x = x,
		y = 35,
		accepts = function(other: number): boolean
			return other == item
		end,
	}
end

-- (The row reads brass, lead, gunpowder, 18 apart, then the arrow and the output.)
local SLOTS: { Core.SlotSpec } = {
	inputSlot(20, BRASS_INGOT),
	inputSlot(56, POWDER),
	{ x = 116, y = 35, output = true, big = true },
}
for _, slot in Upgrades.slots(8, 53) do
	table.insert(SLOTS, slot)
end
table.insert(SLOTS, inputSlot(38, LEAD_INGOT))
assert(
	#SLOTS == LEAD and BRASS == 1 and GUNPOWDER == 2 and OUTPUT == 3 and SPEED == 4 and ENERGY == 5,
	"the Ammo Press's slots"
)

--[[
	The status of a NO_INPUT state's missing part (INPUTS' bits): "No lead", "No brass or
	gunpowder"; "No input" for none (a state saved before lead, or from elsewhere) or anything
	else.
]]
local function missingText(missing: number): string
	if missing < 1 or missing > ALL_MISSING or missing ~= math.floor(missing) then
		return "No input"
	end
	local words: { string } = {}
	for _, input in INPUTS do
		if bit32.btest(missing, input.bit) then
			table.insert(words, input.word)
		end
	end
	local last = table.remove(words) :: string
	if #words == 0 then
		return `No {last}`
	end
	return `No {table.concat(words, ", ")} or {last}`
end

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
	-- (Anything else in an input slot is no input: an old press's Iron Ingots, data from elsewhere.)
	local missing, held = 0, 0
	for _, input in INPUTS do
		if holds(container, input.slot, input.item) then
			held += 1
		else
			missing += input.bit
		end
	end
	-- (Never past the end, whatever the data says: a full arrow finishes on the next tick.)
	progress = math.clamp(math.floor(progress), 0, ticks)
	local state, working = IDLE, false
	if missing ~= 0 then
		-- Nothing to press: idle when it holds none of the three, else waiting for the rest (and
		-- saying which).
		progress = 0
		state = if held > 0 then NO_INPUT + CODES * missing else IDLE
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
			-- (One of each; what is left of an input keeps its wear and data.)
			for _, input in INPUTS do
				local stack = slots[input.slot] :: Items.Stack
				slots[input.slot] = Items.withCount(stack, stack.count - 1)
			end
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
		local code = view.state % CODES
		if view.rate < 0 then
			return `Using {Items.formatEnergy(-view.rate)}/t`
		elseif code == NO_POWER then
			return "No power"
		elseif code == OUTPUT_FULL then
			return "Output full"
		elseif code == NO_INPUT then
			return missingText(view.state // CODES)
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
