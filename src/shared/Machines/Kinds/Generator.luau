--!strict
--[[
	Mekanism Generators' Heat Generator (kind "generator"), burning furnace fuel: BlockList
	`HeatGenerator`, `energy = { capacity = 160 000 J, output = 400 J/t }` (Mekanism's storage, and
	an output twice what it makes, so a network takes all of it).

	One fuel slot that takes anything that burns in a furnace (Crafting/Smelting.fuel > 0), from the
	hand, shift-clicks and transporters through every face; nothing comes out of it. A fuel item
	burns for its furnace burn time in ticks (coal 1 600, a plank 300), and every tick it burns the
	generator makes HEAT_GENERATION J (Mekanism's heatGeneration, 200 J/t): a coal is 320 kJ.

	It burns only as much as it has room for (Mekanism stops when its energy is full): with less
	room than a tick's 200 J it makes what fits and burns that share of a tick (50 J of room: a
	quarter), so no fuel is wasted however slowly the network takes the energy. Full, it keeps what
	is left of the item burning and lights nothing new, and goes on as soon as the network takes
	some. An item lights only when there is room, and is used up then, as a furnace's is. Out of
	burn time, the next item lights in the same tick and makes the rest of that tick's 200 J, so
	neither the flame nor the output dips between two items. What is left burning is counted in
	quanta of energy (Shared/Machines QUANTUM, TICK_QUANTA a tick), so part ticks never make or
	lose energy by rounding.

	Data after the header (Shared/Machines): `burnTime` (ticks left of the item burning; a fraction
	after a part tick) and `burnTotal` (that item's burn time, 0 while out: the flame's full
	height), both at most the longest fuel's burn time (item data from elsewhere is clamped). What
	it makes each tick is the header's RATE (200, or less when it is nearly full; 0 while idle), and
	ACTIVE is 1 while it makes anything. Both burn fields are kept in the item with its energy
	(Mekanism keeps the generator's lava in its item), and the item's tooltip shows what is left
	("Fuel: 80 s").

	Its panel: the fuel slot under the furnace's flame (burn time left), the status line ("Producing
	200 J/t" or "Idle", as WAILA shows it) and the energy bar.

	Mekanism's lava (its tank, lava buckets, lava around it) and nether bonuses don't apply: furnace
	fuel is all it burns.
]]

local Core = require(script.Parent.Parent.Core)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

-- J made per tick of burning (Mekanism's heatGeneration).
local HEAT_GENERATION = 200
-- Quanta of energy (Shared/Machines QUANTUM) in a tick of burning: what is left of an item is
-- counted in these, so part ticks stay exact.
local TICK_QUANTA = HEAT_GENERATION / Core.QUANTUM
-- The longest any item burns (ticks): no burn field goes above it, whatever an item's data says.
local MAX_BURN = 0
for _, fuel in Smelting.fuels() do
	MAX_BURN = math.max(MAX_BURN, fuel.ticks)
end
-- Items lit in one tick at most (a tick's 200 J may finish one item and start the next).
local MAX_LIGHTS = 4

local function burns(item: number): boolean
	return Smelting.fuel(item) > 0
end

-- Whole quanta of energy left in `burn` ticks of burning (the data holds quanta / TICK_QUANTA).
local function quantaOf(burn: number): number
	return math.round(math.clamp(burn, 0, MAX_BURN) * TICK_QUANTA)
end

--[[
	Lights the next fuel item, if there is one and room for what it makes: one of it is used up.
	Returns its burn time in ticks (0: nothing lit).
]]
local function light(container: Container): number
	local fuel = container.slots[1]
	if fuel == nil or Core.room(container) <= 0 then
		return 0
	end
	local ticks = math.min(Smelting.fuel(fuel.item), MAX_BURN)
	if ticks <= 0 then
		return 0
	end
	-- (What is left keeps its wear and data, as a furnace's fuel does.)
	container.slots[1] = Items.withCount(fuel, fuel.count - 1)
	return ticks
end

local function tick(container: Container, _ctx: Core.TickContext)
	local left = quantaOf(Core.get(container, "burnTime"))
	local total = if left > 0 then math.clamp(Core.get(container, "burnTotal"), 0, MAX_BURN) else 0
	local made = 0
	for _ = 1, MAX_LIGHTS do
		if left <= 0 then
			local ticks = light(container)
			if ticks <= 0 then
				break
			end
			left, total = ticks * TICK_QUANTA, ticks
		end
		-- (At most its room: full, the item waits; nearly full, it burns a part of a tick.)
		local got = Core.produce(container, math.min(HEAT_GENERATION - made, left * Core.QUANTUM))
		if got <= 0 then
			break
		end
		made += got
		left -= got / Core.QUANTUM
		if made >= HEAT_GENERATION then
			break
		end
	end
	-- Out: the next item lights now, so the flame never flickers out between two items.
	if left <= 0 then
		local ticks = light(container)
		left, total = ticks * TICK_QUANTA, ticks
	end
	local burn = left / TICK_QUANTA
	Core.set(container, "burnTime", burn)
	-- (Item data from elsewhere: the flame never shows more than full.)
	Core.set(container, "burnTotal", math.max(total, burn))
	Core.set(container, "rate", made)
	Core.set(container, "active", if made > 0 then 1 else 0)
end

-- What is left of a broken generator's fuel, in seconds (its item's tooltip).
Items.addDescriber("burnTime", function(data: Items.Data): string?
	local ticks = Items.dataNumber(data, "burnTime")
	if ticks == nil or ticks <= 0 then
		return nil
	end
	return `Fuel: {Items.thousands(math.ceil(ticks / 20))} s`
end)

return Core.define("generator", {
	slots = { { x = 80, y = 53, accepts = burns } },
	fields = { "burnTime", "burnTotal" },
	keep = { "burnTime", "burnTotal" },
	panel = {
		-- (Minecraft's spacing: the furnace's flame sits at y 36 over its fuel slot at y 53.)
		flame = { x = 80, y = 36, value = "burnTime", total = "burnTotal" },
		status = { x = 8, y = 20 },
	},
	tick = tick,
	status = function(view: Core.View): string?
		if view.rate > 0 then
			return `Producing {Items.formatEnergy(view.rate)}/t`
		end
		return "Idle"
	end,
})
