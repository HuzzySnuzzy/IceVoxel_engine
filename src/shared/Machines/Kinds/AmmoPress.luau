--!strict
--[[
	The Ammo Press (kind "press"; BlockList `AmmoPress`, `energy = { capacity = 20 kJ, input =
	20 kJ/t }`, Config.AmmoPress): an Iron Ingot and a Gunpowder pressed into rounds of the calibre
	its button picks, so turrets (and guns) need not live on loot alone: one operation makes 16
	9mm, 10 5.56 or 5 .308 rounds in 200 ticks at 50 J a tick (10 kJ: an Electric Furnace's item),
	faster with Speed Upgrades (Mekanism's maths, Machines/Upgrades). Gunpowder needs the
	Demolition skill, so the press opens nothing new on its own.

	Slots (frozen):
	  1 ingot      Iron Ingots only: by hand, shift-click and transporters through any face
	  2 gunpowder  Gunpowder only, the same way
	  3 output     the rounds (Minecraft's result frame at (116, 35)): taken by hand, shift-click
	               and transporters, and pushed out on its own (Mekanism's ejector)
	  4 speed      up to 8 Speed Upgrades, at (8, 53)
	  5 energy     up to 8 Energy Upgrades, at (26, 53)
	Data after the header (Shared/Machines), frozen:
	   7 progress       ticks worked on the operation (the arrow: progress / ticksRequired)
	   8 ticksRequired  ticks an operation takes (Config.AmmoPress.Ticks; fewer with cards)
	   9 energyPerTick  J a tick of work uses (Config.AmmoPress.Joules; changed by the cards)
	  10 calibre        the calibre pressed: an index into Config.AmmoPress.Calibres (1 9mm, 2
	                    5.56, 3 .308; a fresh press's 1), which the Calibre button cycles; kept
	                    in the item
	  11 state          IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT (the status line)
	  12 activeDelay    Mekanism's deactivation delay (Machines.showActive: ACTIVE while it works,
	                    its window glows and it stamps)
	RATE is minus the J it used this tick. It takes as much energy as its store holds in a tick
	(`rates`: its capacity, as the Electric Furnace).

	Its panel: the ingot and the gunpowder, the progress arrow and the output in a row, the status
	line, the Calibre button and a line naming what one operation makes ("16 9mm Rounds"), the
	upgrade slots and the energy bar. JEI's "Pressing" (an Iron Ingot and a Gunpowder into rounds,
	the Ammo Press the catalyst) reads `info`: ticks, joules, capacity and each round's count by
	its item name.

	STUB (ammo press builder D implements): the tick only sets state 0 (it presses nothing yet);
	the slots, fields, panel, button, status, line and `info` above are the foundation's and
	frozen. (D's tick stays inert, using nothing, with Config.AmmoPress.Enabled false, as its
	recipe is left out then: Crafting/Recipes, Progression/Ages.)
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
local INGOT, GUNPOWDER, OUTPUT, ENERGY = 1, 2, 3, 5

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local IDLE, NO_POWER, OUTPUT_FULL, NO_INPUT = 0, 1, 2, 3

-- The Calibre button's id, and the calibre's data index (its fourth field).
local CALIBRE_BUTTON = 0
local CALIBRE = Core.HEADER + 4

local IRON, POWDER = Items.id.IronIngot, Items.id.Gunpowder

-- What each calibre choice makes: the round's item, how many, its calibre's name.
type Calibre = { ammo: number, count: number, calibre: string }
local CALIBRES: { Calibre } = {}
for index, entry in PRESS.Calibres do
	local item = rawget(Items.id :: any, entry.ammo)
	local round = Weapons.ammo(item)
	assert(round and entry.count >= 1, `AmmoPress: calibre {index} needs a round and a count`)
	CALIBRES[index] = table.freeze({ ammo = item :: number, count = entry.count, calibre = round.calibre })
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
assert(#SLOTS == ENERGY and INGOT == 1 and GUNPOWDER == 2 and OUTPUT == 3, "the Ammo Press's slots")

-- STUB (builder D): the tick only says state 0 (IDLE) and uses nothing.
local function tick(container: Container, _ctx: Core.TickContext)
	local wasWorking = Core.get(container, "rate") < 0
	Core.set(container, "state", IDLE)
	Core.set(container, "rate", 0)
	Core.showActive(container, wasWorking, false)
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
