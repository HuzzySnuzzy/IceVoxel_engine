--!strict
--[[
	The coolers (kind "cooler"): the Air Conditioner (BlockList `AirConditioner`, `energy = {
	capacity = 20 kJ, input = 500 J/t }`), a thermostat that cools the room it stands in
	(Shared/Seasons/Rooms, server Seasons/RoomWorld) at Config.Seasons.Heat.CoolerJoules J a tick
	per HU, down to AirConditioner HU, in rooms only ("No room" outdoors); and the Electric Fan
	(`ElectricFan`, 2 kJ, 100 J/t in), FanJoules J a tick while it runs for ElectricFan HU in a
	room, and outdoors a cold source near it while it runs (Players/Climate's cold sources).

	Each tick, while on:
	  Air Conditioner  the room next to it (TickContext `climate`: server RoomWorld.climateAt) and
	                   Rooms.thermostat for its set point with a negative maximum, `others` the
	                   room's heat less its own (so it shares the load with other coolers), taking
	                   |P| x CoolerJoules J; outdoors nothing ("No room").
	  Electric Fan     a fan, not a thermostat: in a room it runs while the air is warmer than its
	                   set point (from half a step above it until half a step below: it never
	                   chills a winter room), outdoors whenever it is on; running it takes
	                   FanJoules J a tick for ElectricFan HU.
	With less energy stored than a tick takes, either takes all there is and delivers that share
	("Low power"); with none, nothing ("No power").

	Data after the header (Shared/Machines), frozen (saved items depend on it): the Electric
	Heater's (Kinds/Heater) with a negative `heat`:
	  setPoint     the thermostat's set point (SetPointMin..SetPointMax), kept in the item
	  heat         HU delivered last tick (<= 0: cooling)
	  state        Seasons/HeatStates code: COOLING, AT_SET_POINT, LOW_POWER, NO_POWER, NO_ROOM
	               (an Air Conditioner outdoors), OFF
	  activeDelay  Mekanism's deactivation delay (Machines.showActive)
	  on           1 on (a fresh cooler's), 0 switched off (the Mode button)
	RATE is minus the J it took this tick: WAILA's "Cooling 32 HU" (RATE / CoolerJoules; a fan's
	RATE / FanJoules x its HU), "At set point", "Low power: 5 HU", "No power", "No room", "Off".
	Buttons as the heater's ("-", "+", "Mode").
]]

local Blocks = require(script.Parent.Parent.Parent.Blocks)
local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Rooms = require(script.Parent.Parent.Parent.Seasons.Rooms)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat
-- (Negative: cooling.)
local MAX_COOLING = HEAT.AirConditioner
local JOULES = HEAT.CoolerJoules
local FAN_HEAT = HEAT.ElectricFan
local FAN_JOULES = HEAT.FanJoules
local FAN = Blocks.id.ElectricFan
-- Half a step around the set point: where a fan starts and stops.
local BAND = 0.5

local function setPointOf(container: Container): number
	return math.clamp(math.round(Core.get(container, "setPoint")), HEAT.SetPointMin, HEAT.SetPointMax)
end

local function tick(container: Container, ctx: Core.TickContext)
	local own = math.min(Core.get(container, "heat"), 0)
	local wasWorking = own < 0
	local setPoint = setPointOf(container)
	local fan = container.block == FAN
	-- What it wants (HU, <= 0) and the J that takes.
	local want, joules, state = 0, 0, HeatStates.IDLE
	local sample: Rooms.Sample? = nil
	if Core.get(container, "on") == 0 then
		state = HeatStates.OFF
	else
		local climate = ctx.climate
		if climate then
			sample = (climate(ctx.x, ctx.y, ctx.z))
		end
		if fan then
			local running = true
			if sample then
				local start = if wasWorking then setPoint - BAND else setPoint + BAND
				running = sample.temperature > start
			end
			if running then
				want, joules = FAN_HEAT, FAN_JOULES
			else
				state = HeatStates.AT_SET_POINT
			end
		elseif sample then
			want = Rooms.thermostat(
				setPoint,
				sample.temperature,
				sample,
				sample.outside,
				Rooms.GROUND,
				sample.heat - own,
				MAX_COOLING
			)
			joules = -want * JOULES
			state = HeatStates.AT_SET_POINT
		else
			state = HeatStates.NO_ROOM
		end
	end
	local delivered, used = 0, 0
	if want < 0 then
		local need = Core.quantiseUp(joules)
		local stored = Core.energy(container)
		if stored >= need then
			Core.use(container, need)
			delivered, used = want, need
			local holding = not fan and sample ~= nil and sample.temperature <= setPoint + BAND
			state = if holding then HeatStates.AT_SET_POINT else HeatStates.COOLING
		elseif stored > 0 then
			Core.use(container, stored)
			delivered, used = want * stored / need, stored
			state = HeatStates.LOW_POWER
		else
			state = HeatStates.NO_POWER
		end
	end
	Core.set(container, "heat", delivered)
	Core.set(container, "rate", -used)
	Core.set(container, "state", state)
	Core.showActive(container, wasWorking, delivered < 0)
end

local function onButton(container: Container, button: number)
	if button == HeatStates.BUTTON_MODE then
		Core.set(container, "on", if Core.get(container, "on") ~= 0 then 0 else 1)
		return
	end
	local step = if button == HeatStates.BUTTON_UP then 1 elseif button == HeatStates.BUTTON_DOWN then -1 else 0
	Core.set(container, "setPoint", math.clamp(setPointOf(container) + step, HEAT.SetPointMin, HEAT.SetPointMax))
end

-- The HU (cooling, as a positive number) behind a view's RATE.
local function coolingOf(view: Core.View): number
	local taken = math.max(-view.rate, 0)
	if view.block == FAN then
		return taken / FAN_JOULES * math.abs(FAN_HEAT)
	end
	return taken / JOULES
end

return Core.define("cooler", {
	fields = { "setPoint", "heat", "state", "activeDelay", "on" },
	keep = { "setPoint" },
	defaults = { on = 1 },
	state = "state",
	panel = {
		status = { x = 8, y = 20 },
		lines = { x = 8, y = 34 },
	},
	buttons = {
		{ id = HeatStates.BUTTON_DOWN, x = 8, y = 52, w = 14, h = 14, label = "-" },
		{ id = HeatStates.BUTTON_UP, x = 62, y = 52, w = 14, h = 14, label = "+" },
		{ id = HeatStates.BUTTON_MODE, x = 100, y = 52, w = 40, h = 14, label = "Mode" },
	},
	onButton = onButton,
	tick = tick,
	status = function(view: Core.View): string?
		if view.state == HeatStates.COOLING then
			return `Cooling {Rooms.huText(coolingOf(view))} HU`
		elseif view.state == HeatStates.LOW_POWER then
			return `Low power: {Rooms.huText(coolingOf(view))} HU`
		end
		return HeatStates.name(view.state)
	end,
	lines = function(view: Core.View): { string }
		if view.rate >= 0 then
			return {}
		end
		return { `-{Rooms.huText(coolingOf(view))} HU, {Items.formatEnergy(math.floor(-view.rate + 0.5))}/t` }
	end,
	info = {
		maxCooling = -MAX_COOLING,
		joulesPerHeat = JOULES,
		fanHeat = FAN_HEAT,
		fanJoules = FAN_JOULES,
	},
})
