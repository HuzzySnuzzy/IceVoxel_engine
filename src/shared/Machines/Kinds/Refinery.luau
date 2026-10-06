--!strict
--[[
	The Oil Refinery (kind "refinery"): BuildCraft's refinery on Mekanism's electricity. BlockList
	`OilRefinery`, `energy = { capacity = 40 000 J, input = 40 000 J/t }` (a consumer; a network
	may fill it in a single tick, as Mekanism's machine energy containers take any amount: `rates`
	gives its capacity as its input rate).

	It turns oil into fuel, 1 mB into 1 mB (BuildCraft's oil to fuel recipe, without its heat and
	its gas by-product), 10 mB a tick (a bucket every BASE_TICKS, 100) for BASE_ENERGY_PER_TICK
	(200 J): a bucket of oil takes 100 ticks and 20 kJ.

	Tanks (Shared/Machines' tank rules, the same through every side):
	  oil   input, 10 000 mB of oil: Mechanical Pipes and Oil Buckets fill it
	  fuel  output, 10 000 mB of fuel: pipes and empty buckets take from it, and it pushes its fuel
	        into the pipes and Fluid Tanks around it on its own (the server's ejector)
	Slots: only its Speed and Energy Upgrades (Machines/Upgrades.slots: by hand and shift-click,
	no transporter reaches them, so it is no item inventory).

	Upgrades: Mekanism's maths, as the Electric Furnace's (Machines/Upgrades) with a bucket of oil
	as its operation (Mekanism's Electric Pump makes a bucket its operation the same way): a
	bucket takes 100 x 10^(-speed/8) ticks, truncated (MekanismUtils.getTicks: 74 with one card,
	10 with 8, so 13.5 and 100 mB a tick), a tick of work uses 200 x 10^((2 speed - energy)/8) J
	(getEnergyPerTick: 20 kJ a tick with 8 Speed Upgrades and no Energy Upgrade) and it holds
	40 000 x 10^(energy/8) J (getMaxEnergy). Taking cards out applies at once (energy over a
	smaller capacity is lost, Mekanism's setMaxEnergy).

	Every tick: the tick's share of a bucket (whole mB: 1000 / ticks a tick, the fraction carried
	in `progress`) moves from the oil tank to the fuel tank if a tick's energy is stored (all or
	nothing, as the Electric Furnace). With less oil or fuel room than the share it refines what it
	can and uses that share of the tick's energy, so no oil is ever stuck. No oil: idle; no room for
	fuel: "Output full"; too little energy: "No power" (Mekanism pauses on all three).

	Data after the header (Shared/Machines):
	  progress       mB of the current bucket refined (0..1000; fractions carry over): the panel's
	                 arrow fills once a bucket
	  ticksRequired  ticks a bucket takes (100; fewer with Speed Upgrades)
	  energyPerTick  J a tick of work uses (200; more with Speed, less with Energy Upgrades)
	  state          why it is not working: IDLE (no oil), NO_POWER, OUTPUT_FULL
	  activeDelay    ticks ACTIVE is held on through stops (Shared/Machines.showActive)
	  oil, fuel      the tanks (mB)
	RATE is minus the energy it used this tick, which its status reads: "Using 200 J/t", "No
	power", "Output full" or "Idle". ACTIVE is Mekanism's active state with its 60 tick
	deactivation delay. Its item keeps its energy and both tanks (sustained data); the upgrade
	cards drop.

	Its panel: the oil gauge, Minecraft's arrow and the fuel gauge in a row on the left, the status
	line and the upgrade slots on the right of them, and the energy bar.
]]

local Core = require(script.Parent.Parent.Core)
local Upgrades = require(script.Parent.Parent.Upgrades)
local Fluids = require(script.Parent.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

-- Ticks a bucket of oil takes and J a tick of work uses, without upgrades.
local BASE_TICKS = 100
local BASE_ENERGY_PER_TICK = 200
-- mB a bucket holds: the refinery's operation.
local BUCKET = Fluids.BUCKET
-- Each tank's capacity (mB).
local TANK = 10000

-- Slots and tanks.
local SPEED, ENERGY = 1, 2
local OIL, FUEL = 1, 2

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local IDLE, NO_POWER, OUTPUT_FULL = 0, 1, 2

-- Data that came from elsewhere: a number in 0..max (NaN and junk read 0).
local function clean(value: number, max: number): number
	if value ~= value then
		return 0
	end
	return math.clamp(value, 0, max)
end

local function tick(container: Container, ctx: Core.TickContext)
	-- (RATE still holds last tick's: below 0 when it worked.)
	local wasWorking = Core.get(container, "rate") < 0
	local speed, energyCards = Upgrades.counts(container, SPEED, ENERGY)
	local ticks = Upgrades.ticks(BASE_TICKS, speed)
	local energyPerTick = Upgrades.energyPerTick(BASE_ENERGY_PER_TICK, speed, energyCards)
	Core.set(container, "ticksRequired", ticks)
	Core.set(container, "energyPerTick", energyPerTick)
	Upgrades.setCapacity(container, Upgrades.capacity(ctx.energy.capacity, energyCards))

	local rate = BUCKET / ticks
	-- (Below a whole bucket, whatever the data says.)
	local progress = clean(Core.get(container, "progress"), BUCKET - 1e-9)
	-- The tick's share: the whole mB its rate crosses from where the bucket is.
	local share = math.floor(progress + rate) - math.floor(progress)
	local oil = Core.tankAmount(container, OIL)
	local room = Core.tankRoom(container, FUEL, Fluids.FUEL)
	local amount = math.min(share, oil, room)
	local state, used = IDLE, 0
	if oil <= 0 then
		-- Nothing to refine: the bucket starts over.
		progress = 0
	elseif room <= 0 then
		state = OUTPUT_FULL
	else
		local cost = if amount >= share then energyPerTick else energyPerTick * amount / share
		if not Core.use(container, cost) then
			state = NO_POWER
		else
			used = Core.quantiseUp(cost)
			Core.tankExtract(container, OIL, amount)
			Core.tankInsert(container, FUEL, Fluids.FUEL, amount)
			progress = if amount >= share then progress + rate else math.floor(progress) + amount
			if progress >= BUCKET then
				progress -= BUCKET
			end
		end
	end
	Core.set(container, "progress", progress)
	Core.set(container, "state", state)
	Core.set(container, "rate", -used)
	Core.showActive(container, wasWorking, used > 0)
end

local SLOTS = Upgrades.slots(82, 53)
assert(#SLOTS == ENERGY, "the Oil Refinery's upgrade slots are 1 and 2")

return Core.define("refinery", {
	slots = SLOTS,
	fields = { "progress", "ticksRequired", "energyPerTick", "state", "activeDelay" },
	state = "state",
	tanks = {
		{ name = "oil", capacity = TANK, fluids = { Fluids.OIL }, role = "input", gauge = { x = 7, y = 13 } },
		{ name = "fuel", capacity = TANK, fluids = { Fluids.FUEL }, role = "output", gauge = { x = 57, y = 13 } },
	},
	panel = {
		-- (Between the gauges, at the height of a furnace's arrow.)
		progress = { x = 29, y = 35, value = "progress", total = BUCKET },
		status = { x = 82, y = 20 },
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
	info = {
		-- Ticks a bucket of oil takes and J a tick uses (without upgrades), and mB of fuel per mB of
		-- oil.
		ticksPerBucket = BASE_TICKS,
		energyPerTick = BASE_ENERGY_PER_TICK,
		fuelPerOil = 1,
	},
})
