--!strict
--[[
	The coolers (kind "cooler"): the Air Conditioner (BlockList `AirConditioner`, `energy = {
	capacity = 20 kJ, input = 500 J/t }`), a thermostat that cools the room it stands in
	(Shared/Seasons/Rooms, server Seasons/RoomWorld) at Config.Seasons.Heat.CoolerJoules J a tick
	per HU, down to AirConditioner HU, in rooms only ("No room" outdoors); and the Electric Fan
	(`ElectricFan`, 2 kJ, 100 J/t in), FanJoules J a tick while it runs for ElectricFan HU in a
	room, and outdoors a cold source within FanRadius.

	Data after the header (Shared/Machines), frozen (saved items depend on it): the Electric
	Heater's (Kinds/Heater) with a negative `heat`:
	  setPoint     the thermostat's set point (SetPointMin..SetPointMax), kept in the item
	  heat         HU delivered last tick (<= 0: cooling)
	  state        Seasons/HeatStates code
	  activeDelay  Mekanism's deactivation delay (Machines.showActive)
	  on           1 on (a fresh cooler's), 0 switched off (the Mode button)
	Buttons as the heater's ("-", "+", "Mode"; the fan's set point is not used). Idle until the
	rooms land (no cooling, no power drawn).
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat

local function tick(container: Container, _ctx: Core.TickContext)
	-- (Idle until the rooms land: see the header.)
	local on = Core.get(container, "on") ~= 0
	Core.set(container, "heat", 0)
	Core.set(container, "rate", 0)
	Core.set(container, "state", if on then HeatStates.IDLE else HeatStates.OFF)
	Core.showActive(container, false, false)
end

local function onButton(container: Container, button: number)
	if button == HeatStates.BUTTON_MODE then
		Core.set(container, "on", if Core.get(container, "on") ~= 0 then 0 else 1)
		return
	end
	local step = if button == HeatStates.BUTTON_UP then 1 elseif button == HeatStates.BUTTON_DOWN then -1 else 0
	local setPoint = math.round(Core.get(container, "setPoint")) + step
	Core.set(container, "setPoint", math.clamp(setPoint, HEAT.SetPointMin, HEAT.SetPointMax))
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
		return HeatStates.name(view.state)
	end,
	info = {
		maxCooling = -HEAT.AirConditioner,
		joulesPerHeat = HEAT.CoolerJoules,
		fanHeat = HEAT.ElectricFan,
		fanJoules = HEAT.FanJoules,
	},
})
