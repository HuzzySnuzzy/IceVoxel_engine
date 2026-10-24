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

	Every tick (with Config.Miner.Enabled; switched off it is inert: nothing used or made,
	"Idle"), as the Electric Furnace's: `MinerRules.settings` works out the ticks an item takes,
	the J a tick of work and the store from the ore and the cards installed (Mekanism's maths:
	4800 ticks become 480 with 8 Speed Upgrades, never under the ore's floor; a change of
	`ticksRequired` keeps the share of the item made, not the ticks worked: `Upgrades.rescale`,
	the progress x new / old ticks rounded down, so no card swap at any time skips work and a coal
	costs at least its floor), and then
	  * no ore under it (another block, or nothing ever seen there): NO_ORE, the progress 0;
	  * another ore than `mining`: the progress starts over (the cell is read every tick, so an ore
	    mined away or replaced mid-cycle stops it or restarts it at once);
	  * no room in the output for one more drop (the same item, at most its stack): OUTPUT_FULL,
	    the progress waiting, nothing used (the ejector and the transporters empty it);
	  * less than a tick's J stored: NO_POWER, the progress waiting (all or nothing, Core.use);
	  * else it works a tick (MINING): the progress moves on one, and at `ticksRequired` one drop
	    goes into the output (a new stack table) and the progress starts again.
	Only its energy is kept in its item when broken (placed again, at most its store without
	Energy Upgrades); the output and the cards drop, so the progress and the ore seen go.

	Its panel: the output in its result frame, the progress arrow, the status line, two lines at
	(8, 32) ("Makes Diamond", "4:00 an item": at most two, the panel would put a third over the
	cards; short, as they end about 70 pixels on, before the arrow; the second from the window's
	`ticksRequired`, so none without a window), the upgrade slots and the energy bar. JEI's
	"Duplicating" (an ore block into its drop, its time and energy, the Metal Miner the catalyst)
	reads `info`: the store and each ore's numbers ("<Ore>Ticks", "<Ore>Joules", "<Ore>Floor").
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

-- One of each ore's drop: what goes into the output, and what a stack there must match.
local DROPS: { Items.Stack } = {}
for index, ore in MinerRules.ORES do
	DROPS[index] = table.freeze(assert(Items.newStack(ore.drop, 1)))
end

-- The data index of `ticksRequired` (the panel's second line reads it from the window).
local TICKS_REQUIRED = Core.HEADER + 2

-- Is there room in the output for one more `drop` (the same item, wear and data, within its limit)?
local function fits(container: Container, drop: Items.Stack): boolean
	local limit = Core.slotLimit(container.block, OUTPUT, drop.item)
	local output = container.slots[OUTPUT]
	if output == nil then
		return drop.count <= limit
	end
	return Items.stacksMatch(output, drop) and output.count + drop.count <= limit
end

local function tick(container: Container, ctx: Core.TickContext)
	-- (RATE still holds last tick's: below 0 when it worked.)
	local wasWorking = Core.get(container, "rate") < 0
	if not Config.Miner.Enabled then
		-- Switched off: inert, nothing used or made.
		Core.set(container, "state", MinerRules.packState(STATE.MINING, 0))
		Core.set(container, "rate", 0)
		Core.showActive(container, wasWorking, false)
		return
	end

	-- The cell under it; nil (unloaded and unedited: still what was generated there) is the ore
	-- it was mining, so it keeps on with nobody near.
	local below = ctx.getBlock(ctx.x, ctx.y - 1, ctx.z)
	local ore = MinerRules.ore(if below == nil then Core.get(container, "mining") else below)
	local mining = if ore then ore.block else 0
	local progress = Core.get(container, "progress")
	if mining ~= Core.get(container, "mining") then
		-- Another ore (or none): its mining starts over.
		Core.set(container, "mining", mining)
		progress = 0
	end

	local speed, energy = Upgrades.counts(container, SPEED, ENERGY)
	local ticks, energyPerTick, capacity = 0, 0, Upgrades.capacity(ctx.energy.capacity, energy)
	if ore then
		ticks, energyPerTick, capacity = MinerRules.settings(ore, speed, energy, ctx.energy.capacity)
	end
	-- (Cards in or out keep the share of the item made, rounded down: a coal costs its floor.)
	progress = Upgrades.rescale(progress, Core.get(container, "ticksRequired"), ticks)
	Core.set(container, "ticksRequired", ticks)
	Core.set(container, "energyPerTick", energyPerTick)
	Upgrades.setCapacity(container, capacity)
	-- (Never past the end, whatever the data says: a full arrow finishes on the next tick.)
	progress = math.clamp(math.floor(progress), 0, ticks)

	local code, working = STATE.MINING, false
	if ore == nil then
		code, progress = STATE.NO_ORE, 0
	elseif not fits(container, DROPS[ore.index]) then
		code = STATE.OUTPUT_FULL
	elseif not Core.use(container, energyPerTick) then
		code = STATE.NO_POWER
	else
		working = true
		progress += 1
		if progress >= ticks then
			progress = 0
			local slots = container.slots
			local output = slots[OUTPUT]
			slots[OUTPUT] = if output then Items.withCount(output, output.count + 1) else Items.newStack(ore.drop, 1)
		end
	end
	Core.set(container, "progress", progress)
	Core.set(container, "state", MinerRules.packState(code, if ore then ore.index else 0))
	Core.set(container, "rate", if working then -Core.quantiseUp(energyPerTick) else 0)
	-- (Held on through short stops: Mekanism's blockDeactivationDelay, Shared/Machines.)
	Core.showActive(container, wasWorking, working)
end

-- `ticks` as the panel shows an item's time: "4:00", "0:24", "0:14.9" (tenths when not whole).
local function timeText(ticks: number): string
	-- (A tenth of a second is two ticks.)
	local tenths = ticks // 2
	local minutes, seconds = tenths // 600, (tenths % 600) // 10
	local text = string.format("%d:%02d", minutes, seconds)
	if ticks % 20 ~= 0 then
		text ..= `.{tenths % 10}`
	end
	return text
end

local info: { [string]: number } = { capacity = Config.Miner.Capacity }
for _, ore in MinerRules.ORES do
	info[`{ore.name}Ticks`] = ore.ticks
	info[`{ore.name}Joules`] = ore.joules
	info[`{ore.name}Floor`] = ore.floor
end

local kind = Core.define("miner", {
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
	-- What it makes and how long an item takes (from the window's data: the cards change it).
	lines = function(view: Core.View, data: { number }?): { string }
		local code, index = MinerRules.unpackState(view.state)
		local ore = MinerRules.ORES[index]
		if ore == nil or code == STATE.NO_ORE then
			return {}
		end
		local shown = { `Makes {Items.displayName(ore.drop)}` }
		local ticks = if data then data[TICKS_REQUIRED] else nil
		if type(ticks) == "number" and ticks >= 1 and ticks == math.floor(ticks) and ticks < 2 ^ 31 then
			table.insert(shown, `{timeText(ticks)} an item`)
		end
		return shown
	end,
	info = info,
})
assert(kind.index.ticksRequired == TICKS_REQUIRED, "the Metal Miner's ticksRequired is its second field")

return kind
