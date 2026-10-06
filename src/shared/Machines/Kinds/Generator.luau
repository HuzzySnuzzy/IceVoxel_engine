--!strict
--[[
	Mekanism Generators' Heat Generator (kind "generator"), burning furnace fuel and lava: BlockList
	`HeatGenerator`, `energy = { capacity = 160 000 J, output = 400 J/t }` (Mekanism's storage, and
	an output above the most it makes, so a network takes all of it).

	One burner makes HEAT_GENERATION J (Mekanism's heatGeneration, 200 J) a tick while it burns,
	fed two ways:
	  * Solid fuel in its fuel slot: anything that burns in a furnace (Crafting/Smelting.fuel > 0)
	    and leaves nothing behind, from the hand, shift-clicks and transporters through every face.
	    An item burns for its furnace burn time in ticks (coal 1 600, a plank 300): a coal is
	    320 kJ.
	  * Lava in its lava tank (Mekanism's TileEntityHeatGenerator lavaTank, MekanismGenerators
	    config 10.4: tankCapacity 24 000 mB). Every mB lit burns for LAVA_TICKS_PER_MB (20) ticks,
	    so a bucket is 20 000 ticks, 4 MJ: a Lava Bucket's furnace burn time, 12.5 coal. That is
	    Mekanism's own ratio (it turns a solid fuel into burn time / 20 mB of lava, so a bucket is
	    12.5 coal there too); its heatGenerationFluidRate (10 mB a tick, a bucket in 100 ticks)
	    is left out because solid fuels burn their whole furnace time here, and a bucket would be
	    worth a sixteenth of a coal. Pipes and full buckets fill the tank (Shared/Machines' tank
	    rules: an input tank, through any side), and a Lava Bucket put in the fuel slot is poured
	    into it once all of its 1000 mB fit, leaving the empty Bucket in the slot (Mekanism's
	    FluidFuelInventorySlot.fillOrBurn).
	Transporters take out of the fuel slot, through every face, only what it would not take in
	(the empty Bucket: Mekanism's FluidFuelInventorySlot.forFuel canExtract gives automation an
	item with no lava in it and no fuel value), never coal or a Lava Bucket, so a line feeding it
	Lava Buckets, or coal after one, never jams on the empty Bucket. The hand takes anything.
	The tank's lava burns before a new item lights (Mekanism turns items into lava only when its
	tank has room, so piped lava keeps it busy too); an item already burning burns out first.

	Lava around it (Mekanism's getBoost, heatGenerationLava): every side touching lava (any level,
	the cave twin too: Shared/Fluids) adds LAVA_PER_SIDE (30) J a tick, burning or not and with no
	fuel at all, up to 180 J/t with lava on all six sides. Mekanism's nether bonus (100 J/t) and
	its lava-logged seventh side don't exist here.

	It makes only as much as it has room for (Mekanism stops when its energy is full): the lava
	around it first (it costs nothing), then the burner. With less room than a tick's 200 J it
	makes what fits and burns that share of a tick (50 J of room: a quarter), so no fuel is wasted
	however slowly the network takes the energy. Full, it keeps what is left burning and lights
	nothing new, and goes on as soon as the network takes some. Fuel lights only when there is
	room, and is used up then (an item, or a mB of lava), as a furnace's is. Out of burn
	time, the next lights in the same tick and makes the rest of that tick's 200 J, so neither the
	flame nor the output dips between two items. What is left burning is counted in quanta of
	energy (Shared/Machines QUANTUM, TICK_QUANTA a tick), so part ticks never make or lose energy
	by rounding.

	Data after the header (Shared/Machines): `burnTime` (ticks left of what is burning; a fraction
	after a part tick) and `burnTotal` (that item's burn time, 20 for a mB of lava, 0 while out:
	the flame's full height), both at most the longest solid fuel's burn time (item data from
	elsewhere is clamped), then the tank's `lava` (mB). What it makes each tick is the header's
	RATE (up to 380 J/t: the burner and the lava around it; 0 while idle), and ACTIVE is 1 while the
	burner makes anything (Mekanism's active: burning). Both burn fields are kept in the item with
	its energy and lava (Mekanism keeps the generator's lava in its item), and the item's tooltip
	shows them ("Fuel: 80 s", "Lava: 5,000 mB").

	Its panel: the lava gauge on the left, the status line beside it ("Producing 200 J/t" or
	"Idle", as WAILA shows it), the fuel slot under the furnace's flame (burn time left) and the
	energy bar.

	Mekanism's heat model (a heat capacitor at 10 J/K, losses to the air and to what is below it,
	Carnot efficiency) is left out: what burns is energy. Mekanism also turns solid fuels in the
	slot into lava; here they burn as they are, for the same energy.
]]

local Core = require(script.Parent.Parent.Core)
local Fluids = require(script.Parent.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

-- J made per tick of burning (Mekanism's heatGeneration).
local HEAT_GENERATION = 200
-- Ticks a mB of lava burns for (a bucket: 20 000, its furnace burn time) and the lava tank
-- (Mekanism's tankCapacity).
local LAVA_TICKS_PER_MB = 20
local LAVA_TANK = 24000
-- J a tick from every side touching lava (heatGenerationLava).
local LAVA_PER_SIDE = 30
-- Quanta of energy (Shared/Machines QUANTUM) in a tick of burning: what is left burning is
-- counted in these, so part ticks stay exact.
local TICK_QUANTA = HEAT_GENERATION / Core.QUANTUM
-- Fuel slot and lava tank.
local FUEL, LAVA = 1, 1

-- Does `item` burn in the fuel slot as it is (a furnace fuel that leaves nothing behind)?
local function burnsSolid(item: number): boolean
	return Smelting.fuel(item) > 0 and Items.craftingRemainder(item) == nil
end

-- The longest any item burns here (ticks): no burn field goes above it, whatever an item's data
-- says.
local MAX_BURN = 0
for _, fuel in Smelting.fuels() do
	if burnsSolid(fuel.item) then
		MAX_BURN = math.max(MAX_BURN, fuel.ticks)
	end
end
-- Things lit in one tick at most (a tick's 200 J may finish one and start the next).
local MAX_LIGHTS = 4

-- What the fuel slot takes: solid fuel, and Lava Buckets for the tank.
local function accepts(item: number): boolean
	return burnsSolid(item) or Fluids.ofBucket(item) == Fluids.LAVA
end

-- What transporters may take out of it: only what it would not take in (the empty Bucket a
-- poured Lava Bucket leaves), so automation never pulls its fuel back out.
local function gives(item: number): boolean
	return not accepts(item)
end

-- Whole quanta of energy left in `burn` ticks of burning (the data holds quanta / TICK_QUANTA).
local function quantaOf(burn: number): number
	return math.round(math.clamp(burn, 0, MAX_BURN) * TICK_QUANTA)
end

--[[
	A full bucket in the fuel slot goes into the lava tank once all of it fits, leaving its
	remainder (the empty Bucket) in the slot: Mekanism's FluidFuelInventorySlot.fillOrBurn (which
	also gives up on a stack of more than one).
]]
local function pour(container: Container)
	local stack = container.slots[FUEL]
	if stack == nil or stack.count ~= 1 then
		return
	end
	local fluid = Fluids.ofBucket(stack.item)
	if fluid ~= 0 and Core.pourBucket(container, fluid) then
		local remainder = Items.craftingRemainder(stack.item)
		container.slots[FUEL] = if remainder then Items.newStack(remainder, 1) else nil
	end
end

--[[
	Lights what burns next, if there is room for what it makes: a mB of lava from the tank, else
	one solid fuel item (used up). Returns its burn time in ticks (0: nothing lit).
]]
local function light(container: Container): number
	if Core.room(container) <= 0 then
		return 0
	end
	if Core.tankAmount(container, LAVA) >= 1 then
		Core.tankExtract(container, LAVA, 1)
		return LAVA_TICKS_PER_MB
	end
	local fuel = container.slots[FUEL]
	if fuel == nil or not burnsSolid(fuel.item) then
		return 0
	end
	local ticks = math.min(Smelting.fuel(fuel.item), MAX_BURN)
	-- (What is left keeps its wear and data, as a furnace's fuel does.)
	container.slots[FUEL] = Items.withCount(fuel, fuel.count - 1)
	return ticks
end

-- Sides of the generator touching lava (unknown cells count as none).
local function lavaSides(ctx: Core.TickContext): number
	local getBlock = ctx.getBlock
	local x, y, z = ctx.x, ctx.y, ctx.z
	local sides = 0
	for _, offset in { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } } do
		local block = getBlock(x + offset[1], y + offset[2], z + offset[3])
		if block and Fluids.ofBlock(block) == Fluids.LAVA then
			sides += 1
		end
	end
	return sides
end

local function tick(container: Container, ctx: Core.TickContext)
	pour(container)
	-- The lava around it first: free heat.
	local sides = lavaSides(ctx)
	local made = if sides > 0 then Core.produce(container, sides * LAVA_PER_SIDE) else 0

	local left = quantaOf(Core.get(container, "burnTime"))
	local total = if left > 0 then math.clamp(Core.get(container, "burnTotal"), 0, MAX_BURN) else 0
	local burnt = 0
	for _ = 1, MAX_LIGHTS do
		if left <= 0 then
			local ticks = light(container)
			if ticks <= 0 then
				break
			end
			left, total = ticks * TICK_QUANTA, ticks
		end
		-- (At most its room: full, the fuel waits; nearly full, it burns a part of a tick.)
		local got = Core.produce(container, math.min(HEAT_GENERATION - burnt, left * Core.QUANTUM))
		if got <= 0 then
			break
		end
		burnt += got
		left -= got / Core.QUANTUM
		if burnt >= HEAT_GENERATION then
			break
		end
	end
	-- Out: the next lights now, so the flame never flickers out between two items.
	if left <= 0 then
		local ticks = light(container)
		left, total = ticks * TICK_QUANTA, ticks
	end
	local burn = left / TICK_QUANTA
	Core.set(container, "burnTime", burn)
	-- (Item data from elsewhere: the flame never shows more than full.)
	Core.set(container, "burnTotal", math.max(total, burn))
	Core.set(container, "rate", made + burnt)
	Core.set(container, "active", if burnt > 0 then 1 else 0)
end

-- What is left of a broken generator's burning item or mB of lava, in seconds (its item's
-- tooltip).
Items.addDescriber("burnTime", function(data: Items.Data): string?
	local ticks = Items.dataNumber(data, "burnTime")
	if ticks == nil or ticks <= 0 then
		return nil
	end
	return `Fuel: {Items.thousands(math.ceil(ticks / 20))} s`
end)

return Core.define("generator", {
	slots = { { x = 80, y = 53, accepts = accepts, extract = { 0, 1, 2, 3, 4, 5 }, takes = gives } },
	fields = { "burnTime", "burnTotal" },
	keep = { "burnTime", "burnTotal" },
	tanks = {
		-- (Mekanism's lava tank, in a standard gauge on the left: its GUI has a wide one.)
		{ name = "lava", capacity = LAVA_TANK, fluids = { Fluids.LAVA }, role = "input", gauge = { x = 7, y = 13 } },
	},
	panel = {
		-- (Minecraft's spacing: the furnace's flame sits at y 36 over its fuel slot at y 53.)
		flame = { x = 80, y = 36, value = "burnTime", total = "burnTotal" },
		-- (Right of the lava gauge, above the flame.)
		status = { x = 30, y = 20 },
	},
	tick = tick,
	status = function(view: Core.View): string?
		if view.rate > 0 then
			return `Producing {Items.formatEnergy(view.rate)}/t`
		end
		return "Idle"
	end,
	info = {
		-- J a tick of burning makes, mB of lava it takes (a twentieth), J/t each side touching
		-- lava adds, and the longest an item burns (ticks).
		heatGeneration = HEAT_GENERATION,
		lavaPerTick = 1 / LAVA_TICKS_PER_MB,
		lavaPerSide = LAVA_PER_SIDE,
		maxBurn = MAX_BURN,
	},
})
