--!strict
--[[
	The Oil Heater (kind "oilheater", fuel only: BlockList `OilHeater`, `energy = { capacity = 0
	}`): a thermostat burning Oil or Fuel from its tank (Config.Seasons.Heat.OilTank mB: pipes and
	buckets fill it, Shared/Machines' input tank rules) for up to OilHeater HU in the room it
	stands in (server Seasons/RoomWorld), and radiant warmth (Players/Climate). At full output a mB
	of Oil lasts OilTicks, of Fuel FuelTicks; what it burns scales with what it gives ("No fuel"
	when the tank is dry).

	Data after the header (Shared/Machines), frozen (saved items depend on it):
	  setPoint  the thermostat's set point (SetPointMin..SetPointMax), kept in the item
	  heat      HU delivered last tick
	  state     Seasons/HeatStates code
	  burning   the share of a mB still burning (0..1)
	  on        1 on (a fresh heater's), 0 switched off (the Mode button)
	then the tank `fuel` (mB) and `fuelFluid` (Shared/Fluids id: Oil or Fuel). Buttons "-", "+",
	"Mode". No energy: no energy bar, cables never connect. Idle until the rooms land (nothing
	burns).
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Fluids = require(script.Parent.Parent.Parent.Fluids)
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
	Core.set(container, "active", 0)
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

return Core.define("oilheater", {
	fuelOnly = true,
	fields = { "setPoint", "heat", "state", "burning", "on" },
	keep = { "setPoint" },
	defaults = { on = 1 },
	state = "state",
	tanks = {
		{
			name = "fuel",
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
		return HeatStates.name(view.state)
	end,
	info = {
		maxHeat = HEAT.OilHeater,
		oilTicks = HEAT.OilTicks,
		fuelTicks = HEAT.FuelTicks,
	},
})
