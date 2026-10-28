--!strict
--[[
	The state codes of the heaters, coolers and stoves (Shared/Machines kinds "heater", "cooler",
	"stove" and "oilheater": their `state` field, KindSpec `state`), and the status line each one
	reads (WAILA and the panel, with RATE and `heat`: "Heating 32 HU"). Pure data, requiring
	nothing, so the kinds, their panels and WAILA agree. Codes are append-only (saved in the
	machine's data, sent in Machines records); 0 is a machine that has done nothing yet.
]]

local HeatStates = {}

HeatStates.IDLE = 0
HeatStates.HEATING = 1
HeatStates.COOLING = 2
HeatStates.AT_SET_POINT = 3
HeatStates.NO_POWER = 4
HeatStates.LOW_POWER = 5
HeatStates.NO_FUEL = 6
HeatStates.NO_ROOM = 7
HeatStates.OFF = 8
HeatStates.STANDBY = 9

HeatStates.NAMES = table.freeze({
	[0] = "Idle",
	[1] = "Heating",
	[2] = "Cooling",
	[3] = "At set point",
	[4] = "No power",
	[5] = "Low power",
	[6] = "No fuel",
	[7] = "No room",
	[8] = "Off",
	[9] = "Standby",
} :: { [number]: string })

-- The panel buttons' ids (Shared/Machines ButtonSpec `id`): the thermostat's set point down and
-- up, and on / off.
HeatStates.BUTTON_DOWN = 0
HeatStates.BUTTON_UP = 1
HeatStates.BUTTON_MODE = 2

-- The status word of state `code` ("Idle" for an unknown one).
function HeatStates.name(code: number): string
	return HeatStates.NAMES[code] or HeatStates.NAMES[HeatStates.IDLE]
end

return HeatStates
