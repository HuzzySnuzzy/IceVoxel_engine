--!strict
--[[
	The Metal Miner (kind "miner"; BlockList `MetalMiner`, `energy = { capacity = 200 kJ, input =
	200 kJ/t }`, Config.Miner): on an ore block it makes that ore's drop forever for energy
	(Machines/MinerRules: the ores, their drops and numbers). Between Mekanism's Digital Miner and
	the void ore miners of other mods: it needs a real ore block under it, and coal never pays.

	"Under it" is the cell directly below (y - 1), read with ctx.getBlock (the server's known
	blocks: the loaded chunk, else its edit list; nil for an unloaded, unedited cell, which is
	still what was generated: the ore it was mining), so a miner works with nobody near, like
	every machine.

	Slots (frozen):
	  1 output  the drops (Minecraft's result frame at (116, 35)): taken by hand, shift-click and
	            transporters through any face, and pushed out on its own every 10 ticks into the
	            chests and transporters next to it (Mekanism's ejector)
	  2 speed   up to 8 Speed Upgrades, at (8, 53) (Machines/Upgrades)
	  3 energy  up to 8 Energy Upgrades, at (26, 53)
	Data after the header (Shared/Machines), frozen:
	   7 progress       ticks worked on the item being made (the arrow: progress / ticksRequired)
	   8 ticksRequired  ticks an item takes (its ore's, fewer with Speed Upgrades)
	   9 energyPerTick  J a tick of work uses (its ore's, changed by the cards, never under the
	                    ore's floor over its ticks)
	  10 mining         the ore block seen under it (0: none): another one starts over
	  11 state          MinerRules.packState(code, ore index): MINING ("Mining Diamond Ore"),
	                    NO_POWER, OUTPUT_FULL, NO_ORE ("No ore below")
	  12 activeDelay    Mekanism's deactivation delay (Machines.showActive: ACTIVE while it works,
	                    its grille glows and its drill loops)
	RATE is minus the J it used this tick. It takes as much energy as its store holds in a tick
	(`rates`: its capacity, as the Electric Furnace).

	Its panel: the output in its result frame, the progress arrow, the status line, two lines at
	(8, 32) ("Diamond Ore → Diamond", "4:00 an item": at most two, the panel would put a third over
	the cards; about 70 pixels before the arrow), the upgrade slots and the energy bar. JEI's "Duplicating" (an ore block into its drop, its
	time and energy, the Metal Miner the catalyst) reads `info`: the store and each ore's numbers
	("<Ore>Ticks", "<Ore>Joules", "<Ore>Floor").

	STUB (miner builder C implements): the tick only sets state 0 (it mines nothing yet) and the
	lines are none; the slots, fields, panel, status and `info` above are the foundation's and
	frozen. (C's tick stays inert, using nothing, with Config.Miner.Enabled false, as its recipe is
	left out then: Crafting/Recipes, Progression/Ages.)
]]

local Core = require(script.Parent.Parent.Core)
local Upgrades = require(script.Parent.Parent.Upgrades)
local MinerRules = require(script.Parent.Parent.MinerRules)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local STATE = MinerRules.STATE

-- Slots.
local OUTPUT, SPEED, ENERGY = 1, 2, 3

local SLOTS: { Core.SlotSpec } = {
	{ x = 116, y = 35, output = true, big = true },
}
for _, slot in Upgrades.slots(8, 53) do
	table.insert(SLOTS, slot)
end
assert(#SLOTS == ENERGY and SPEED == 2, "the Metal Miner's upgrade slots are 2 and 3")
assert(OUTPUT == 1, "the Metal Miner's output is slot 1")

-- STUB (builder C): the tick only says state 0 and uses nothing.
local function tick(container: Container, _ctx: Core.TickContext)
	local wasWorking = Core.get(container, "rate") < 0
	Core.set(container, "state", MinerRules.packState(STATE.MINING, 0))
	Core.set(container, "rate", 0)
	Core.showActive(container, wasWorking, false)
end

local info: { [string]: number } = { capacity = Config.Miner.Capacity }
for _, ore in MinerRules.ORES do
	info[`{ore.name}Ticks`] = ore.ticks
	info[`{ore.name}Joules`] = ore.joules
	info[`{ore.name}Floor`] = ore.floor
end

return Core.define("miner", {
	slots = SLOTS,
	fields = { "progress", "ticksRequired", "energyPerTick", "mining", "state", "activeDelay" },
	state = "state",
	panel = {
		progress = { x = 79, y = 34, value = "progress", total = "ticksRequired" },
		status = { x = 8, y = 20 },
		lines = { x = 8, y = 32 },
	},
	tick = tick,
	-- Mekanism's machine energy containers take any amount: up to its capacity in a tick.
	rates = function(container: Container, _energy: Core.EnergySpec): (number, number)
		return Core.capacity(container), 0
	end,
	status = function(view: Core.View): string?
		local code, index = MinerRules.unpackState(view.state)
		local ore = MinerRules.ORES[index]
		if code == STATE.NO_POWER then
			return "No power"
		elseif code == STATE.OUTPUT_FULL then
			return "Output full"
		elseif code == STATE.NO_ORE then
			return "No ore below"
		elseif ore then
			return `Mining {Items.displayName(ore.block)}`
		end
		return "Idle"
	end,
	info = info,
})
