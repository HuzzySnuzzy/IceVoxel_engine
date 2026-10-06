--!strict
--[[
	The Combustion Generator (kind "combustion"): burns the fuel the Oil Refinery makes, BuildCraft's
	combustion engine as a Mekanism generator (its Gas-Burning Generator's shape: a fuel tank, a
	store and a steady output). BlockList `CombustionGenerator`, `energy = { capacity = 1 MJ,
	output = 5 kJ/t }`: a producer whose output is twice what it makes, so a network takes all of
	it.

	It makes PRODUCTION (2 500) J a tick, and a mB of fuel burns for TICKS_PER_MB (4) ticks
	(ENERGY_PER_MB, 10 000 J): a bucket burns for 4 000 ticks (200 s) and makes 10 MJ, the
	strongest fuel there is: 2.5 Lava Buckets (4 MJ each) or about 31 coal (320 kJ each) in a Heat
	Generator, and 12.5 times its output. Its fuel tank (input, 10 000 mB: 10 buckets, 100 MJ) is
	filled by Mechanical Pipes and Fuel Buckets (Shared/Machines' tank rules, through any side);
	nothing comes out of it. It has no slots.

	Like the Heat Generator it makes only as much as it has room for: a mB is taken from the tank
	when it lights (only with room) and burns over the next ticks; with less room than a tick's
	2 500 J it makes what fits and keeps the rest of its mB burning, counted in quanta of energy
	(Shared/Machines QUANTUM), so no fuel is wasted and no energy made or lost by rounding. Full,
	it keeps what is left of its mB and takes no more.

	Data after the header (Shared/Machines): `burning` (the part of a mB still burning, 0..1, kept
	in the item so not a joule is lost) and the tank's `fuel` (mB). RATE is what it made this tick
	(2 500, less when nearly full, 0 while idle) and ACTIVE whether it made anything; its status is
	"Producing 2.5 kJ/t" or "Idle", as WAILA shows it. Its item keeps its energy and fuel.

	Its panel: the fuel gauge on the left, the status line beside it and the energy bar.
]]

local Core = require(script.Parent.Parent.Core)
local Fluids = require(script.Parent.Parent.Parent.Fluids)
local Items = require(script.Parent.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

-- J made per tick of burning, ticks a mB burns for and J a mB makes.
local PRODUCTION = 2500
local TICKS_PER_MB = 4
local ENERGY_PER_MB = PRODUCTION * TICKS_PER_MB
-- The fuel tank (mB).
local TANK = 10000
local FUEL = 1
-- Quanta of energy (Shared/Machines QUANTUM) in a mB: the part still burning is counted in these.
local MB_QUANTA = ENERGY_PER_MB / Core.QUANTUM
-- mB lit in one tick at most (the rest of one and the next, with a spare).
local MAX_LIGHTS = 3

local function tick(container: Container, _ctx: Core.TickContext)
	-- (Item data from elsewhere: at most one mB, whole quanta.)
	local left = math.round(math.clamp(Core.get(container, "burning"), 0, 1) * MB_QUANTA)
	local made = 0
	for _ = 1, MAX_LIGHTS do
		if left <= 0 then
			-- Light the next mB, only with room for what it makes.
			if Core.room(container) <= 0 then
				break
			end
			local _, took = Core.tankExtract(container, FUEL, 1)
			if took <= 0 then
				break
			end
			left = MB_QUANTA
		end
		local got = Core.produce(container, math.min(PRODUCTION - made, left * Core.QUANTUM))
		if got <= 0 then
			break
		end
		made += got
		left -= got / Core.QUANTUM
		if made >= PRODUCTION then
			break
		end
	end
	Core.set(container, "burning", left / MB_QUANTA)
	Core.set(container, "rate", made)
	Core.set(container, "active", if made > 0 then 1 else 0)
end

return Core.define("combustion", {
	fields = { "burning" },
	keep = { "burning" },
	tanks = {
		{ name = "fuel", capacity = TANK, fluids = { Fluids.FUEL }, role = "input", gauge = { x = 7, y = 13 } },
	},
	panel = {
		-- (Right of the fuel gauge.)
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
		-- mB of fuel a tick takes (a quarter) and J a mB makes.
		fuelPerTick = 1 / TICKS_PER_MB,
		energyPerMb = ENERGY_PER_MB,
	},
})
