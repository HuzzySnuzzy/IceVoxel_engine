--!strict
--[[
	The Oil Heater (kind "oilheater", fuel only: BlockList `OilHeater`, `energy = { capacity = 0
	}`): a thermostat burning Oil or Fuel from its tank (Config.Seasons.Heat.OilTank mB: pipes and
	buckets fill it, Shared/Machines' input tank rules) for up to OilHeater HU in the room it
	stands in (server Seasons/RoomWorld), and radiant warmth (Players/Climate). At full output a mB
	of Oil lasts OilTicks, of Fuel FuelTicks; what it burns scales with what it gives, so at 19.5
	of its 35 HU a mB of Oil lasts 54 ticks and a bucket 45 minutes ("No fuel" when the tank is
	dry). Outdoors it burns nothing ("No room": it keeps a room at its set point, the stove is
	the fire for the open air).

	Each tick, on and in a room: Rooms.thermostat for its set point (TickContext `climate`, with
	`others` the room's heat less its own, as the Electric Heater's), then the share of a mB that
	takes, from what still burns (`burning`) and then a whole mB lit from the tank (Shared/Machines
	`tankExtract`); with the tank dry it delivers the share it could burn. A mB burns at the rate of
	the fluid in the tank (Oil's, the faster, once the tank is dry).

	Data after the header (Shared/Machines), frozen (saved items depend on it):
	  setPoint  the thermostat's set point (SetPointMin..SetPointMax), kept in the item
	  heat      HU delivered last tick
	  state     Seasons/HeatStates code: HEATING, AT_SET_POINT (within half a step or above),
	            NO_FUEL, NO_ROOM, OFF
	  burning   the share of a mB still burning (0..1)
	  on        1 on (a fresh heater's), 0 switched off (the Mode button)
	then the tank `fuel` (mB) and `fuelFluid` (Shared/Fluids id: Oil or Fuel). RATE is the HU it
	gives this tick (it holds no energy: WAILA's "Heating 32 HU"), ACTIVE 1 while it burns (its
	window glows, its light is on, it roars). Buttons "-", "+", "Mode". No energy: no energy bar,
	cables never connect.
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Fluids = require(script.Parent.Parent.Parent.Fluids)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Rooms = require(script.Parent.Parent.Parent.Seasons.Rooms)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat
local MAX_HEAT = HEAT.OilHeater
local TANK = "fuel"
-- mB lit in one tick at most (a tick takes at most 1 / OilTicks of one).
local MAX_LIGHTS = 2

local function setPointOf(container: Container): number
	return math.clamp(math.round(Core.get(container, "setPoint")), HEAT.SetPointMin, HEAT.SetPointMax)
end

-- Ticks a mB lasts at full output, burning the tank's fluid.
local function ticksPerMb(container: Container): number
	return if Core.tankFluid(container, TANK) == Fluids.FUEL then HEAT.FuelTicks else HEAT.OilTicks
end

local function tick(container: Container, ctx: Core.TickContext)
	local own = math.max(Core.get(container, "heat"), 0)
	local burning = math.clamp(Core.get(container, "burning"), 0, 1)
	local setPoint = setPointOf(container)
	local want, state = 0, HeatStates.IDLE
	local sample: Rooms.Sample? = nil
	if Core.get(container, "on") == 0 then
		state = HeatStates.OFF
	else
		local climate = ctx.climate
		if climate then
			sample = (climate(ctx.x, ctx.y, ctx.z))
		end
		if sample then
			want = Rooms.thermostat(
				setPoint,
				sample.temperature,
				sample,
				sample.outside,
				Rooms.GROUND,
				sample.heat - own,
				MAX_HEAT
			)
			state = HeatStates.AT_SET_POINT
		else
			state = HeatStates.NO_ROOM
		end
	end
	local delivered = 0
	if want > 0 then
		-- The share of a mB this tick takes, burnt from what burns, then from the tank.
		local need = want / MAX_HEAT / ticksPerMb(container)
		local left = need
		for _ = 1, MAX_LIGHTS do
			if burning <= 0 then
				local _, took = Core.tankExtract(container, TANK, 1)
				if took <= 0 then
					break
				end
				burning = 1
			end
			local take = math.min(burning, left)
			burning -= take
			left -= take
			if left <= 0 then
				break
			end
		end
		delivered = want * (need - math.max(left, 0)) / need
		if delivered <= 0 then
			delivered, state = 0, HeatStates.NO_FUEL
		elseif sample and sample.temperature < setPoint - 0.5 then
			state = HeatStates.HEATING
		end
	end
	Core.set(container, "burning", burning)
	Core.set(container, "heat", delivered)
	Core.set(container, "rate", delivered)
	Core.set(container, "state", state)
	Core.set(container, "active", if delivered > 0 then 1 else 0)
end

local function onButton(container: Container, button: number)
	if button == HeatStates.BUTTON_MODE then
		Core.set(container, "on", if Core.get(container, "on") ~= 0 then 0 else 1)
		return
	end
	local step = if button == HeatStates.BUTTON_UP then 1 elseif button == HeatStates.BUTTON_DOWN then -1 else 0
	Core.set(container, "setPoint", math.clamp(setPointOf(container) + step, HEAT.SetPointMin, HEAT.SetPointMax))
end

return Core.define("oilheater", {
	fuelOnly = true,
	fields = { "setPoint", "heat", "state", "burning", "on" },
	keep = { "setPoint" },
	defaults = { on = 1 },
	state = "state",
	tanks = {
		{
			name = TANK,
			capacity = HEAT.OilTank,
			fluids = { Fluids.OIL, Fluids.FUEL },
			role = "input",
			gauge = { x = 7, y = 13 },
		},
	},
	panel = {
		status = { x = 30, y = 20 },
		lines = { x = 30, y = 34 },
	},
	buttons = {
		{ id = HeatStates.BUTTON_DOWN, x = 30, y = 52, w = 14, h = 14, label = "-" },
		{ id = HeatStates.BUTTON_UP, x = 84, y = 52, w = 14, h = 14, label = "+" },
		{ id = HeatStates.BUTTON_MODE, x = 110, y = 52, w = 40, h = 14, label = "Mode" },
	},
	onButton = onButton,
	tick = tick,
	status = function(view: Core.View): string?
		if view.state == HeatStates.HEATING then
			return `Heating {Rooms.huText(view.rate)} HU`
		end
		return HeatStates.name(view.state)
	end,
	lines = function(view: Core.View): { string }
		if view.rate <= 0 then
			return {}
		end
		return { `{Rooms.huText(view.rate)} HU` }
	end,
	info = {
		maxHeat = MAX_HEAT,
		oilTicks = HEAT.OilTicks,
		fuelTicks = HEAT.FuelTicks,
	},
})
