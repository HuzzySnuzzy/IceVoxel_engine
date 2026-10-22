--!strict
--[[
	The Electric Heater (kind "heater"; BlockList `ElectricHeater`, `energy = { capacity = 16 kJ,
	input = 400 J/t }`): a thermostat that warms the room it stands in (Shared/Seasons/Rooms,
	server Seasons/RoomWorld) at Config.Seasons.Heat.HeaterJoules J a tick per HU, up to
	ElectricHeater HU; convective (no radiant warmth in a room). Outdoors (no room) it is a space
	heater of SpaceHeater HU, warming players within SpaceHeaterRadius (Players/Climate's heat
	sources: Tough As Nails' +3, registered with that radius); with no player within
	StandbyRadius it stands by.

	Each tick, while on: the room next to it (TickContext `climate`: server RoomWorld.climateAt, its
	heat summed for the call) and Rooms.thermostat for its set point, with `others` the room's heat
	less its own (`heat`), so several thermostats in one room share the load without fighting
	(each sees what the others give now); outdoors the space heater's HU while a player is near
	(TickContext `near`, server RoomWorld.playerNear, by the players' positions with the rooms off
	too; a context without it counts a player near).
	It takes P x HeaterJoules J (Shared/Machines `use`); with less stored it takes all there is
	and delivers that share ("Low power"), with none nothing ("No power").

	Data after the header (Shared/Machines), frozen (saved items depend on it):
	  setPoint     the thermostat's set point (Temperature's scale, SetPointMin..SetPointMax),
	               kept in the item
	  heat         HU delivered last tick (what RoomWorld reads; >= 0)
	  state        Seasons/HeatStates code (the status line): HEATING (delivering, the room below
	               its set point by more than half a step, or outdoors), AT_SET_POINT (within half
	               a step or above: holding it, whatever that takes), LOW_POWER, NO_POWER, STANDBY
	               (outdoors, nobody near), OFF
	  activeDelay  Mekanism's deactivation delay (Machines.showActive: ACTIVE while it delivers,
	               the block's window glows and hums)
	  on           1 on (a fresh heater's), 0 switched off (the Mode button)
	RATE is minus the J it took this tick (a consumer's), so WAILA's status reads the HU without
	the window: "Heating 32 HU" (RATE / HeaterJoules), "At set point", "Low power: 12 HU",
	"No power", "Standby", "Off". The panel's line: "20 HU, 78 J/t" (Rooms.huText: whole from 10
	HU up, J/t rounded).
	Buttons (Seasons/HeatStates ids): "-" (BUTTON_DOWN), "+" (BUTTON_UP), "Mode" (BUTTON_MODE: on /
	off). The set point steps by 1 within SetPointMin..SetPointMax.
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Rooms = require(script.Parent.Parent.Parent.Seasons.Rooms)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat
local MAX_HEAT = HEAT.ElectricHeater
local JOULES = HEAT.HeaterJoules

-- The set point, whole and within its range (item data from elsewhere).
local function setPointOf(container: Container): number
	return math.clamp(math.round(Core.get(container, "setPoint")), HEAT.SetPointMin, HEAT.SetPointMax)
end

-- Is a player within `radius` blocks (TickContext `near`; without one: yes)?
local function playerNear(ctx: Core.TickContext, radius: number): boolean
	local near = ctx.near
	if near == nil then
		return true
	end
	return near(ctx.x, ctx.y, ctx.z, radius) == true
end

local function tick(container: Container, ctx: Core.TickContext)
	local own = math.max(Core.get(container, "heat"), 0)
	local wasWorking = own > 0
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
		elseif playerNear(ctx, HEAT.StandbyRadius) then
			want = HEAT.SpaceHeater
		else
			state = HeatStates.STANDBY
		end
	end
	local delivered, used = 0, 0
	if want > 0 then
		local need = Core.quantiseUp(want * JOULES)
		local stored = Core.energy(container)
		if stored >= need then
			Core.use(container, need)
			delivered, used = want, need
			local holding = sample ~= nil and sample.temperature >= setPoint - 0.5
			state = if holding then HeatStates.AT_SET_POINT else HeatStates.HEATING
		elseif stored > 0 then
			-- (Too little: all of it, for that share.)
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
	Core.showActive(container, wasWorking, delivered > 0)
end

local function onButton(container: Container, button: number)
	if button == HeatStates.BUTTON_MODE then
		Core.set(container, "on", if Core.get(container, "on") ~= 0 then 0 else 1)
		return
	end
	local step = if button == HeatStates.BUTTON_UP then 1 elseif button == HeatStates.BUTTON_DOWN then -1 else 0
	Core.set(container, "setPoint", math.clamp(setPointOf(container) + step, HEAT.SetPointMin, HEAT.SetPointMax))
end

-- The HU behind a view's RATE (J taken a tick, HeaterJoules each).
local function heatOf(view: Core.View): number
	return math.max(-view.rate, 0) / JOULES
end

return Core.define("heater", {
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
		if view.state == HeatStates.HEATING then
			return `Heating {Rooms.huText(heatOf(view))} HU`
		elseif view.state == HeatStates.LOW_POWER then
			return `Low power: {Rooms.huText(heatOf(view))} HU`
		end
		return HeatStates.name(view.state)
	end,
	lines = function(view: Core.View): { string }
		if view.rate >= 0 then
			return {}
		end
		return { `{Rooms.huText(heatOf(view))} HU, {Items.formatEnergy(math.floor(-view.rate + 0.5))}/t` }
	end,
	info = {
		maxHeat = MAX_HEAT,
		joulesPerHeat = JOULES,
		spaceHeater = HEAT.SpaceHeater,
	},
})
