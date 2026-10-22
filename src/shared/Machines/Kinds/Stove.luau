--!strict
--[[
	The Wood Stove (kind "stove", fuel only: BlockList `WoodStove`, `energy = { capacity = 0 }`):
	burns furnace fuel (Crafting/Smelting.fuel, anything that leaves nothing behind) for
	Config.Seasons.Heat.StoveBurnFactor times its furnace burn time (a coal 320 s, a log 60 s),
	giving WoodStove HU to the room it stands in while it burns (server Seasons/RoomWorld), and
	radiant warmth (Players/Climate). Switched off it holds its fuel.

	Data after the header (Shared/Machines), frozen (saved items depend on it):
	  burnTime   ticks left of what burns (kept in the item)
	  burnTotal  that item's burn ticks (the flame's full height; kept in the item)
	  on         1 on (a fresh stove's), 0 off (the Mode button: holds the fuel)
	  heat       HU delivered last tick
	  state      Seasons/HeatStates code
	One fuel slot under the furnace's flame; the "On/Off" button (BUTTON_MODE). No energy: no
	energy bar, cables never connect. Idle until the rooms land (nothing burns).
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat

-- Does `item` burn in the stove (a furnace fuel that leaves nothing behind)?
local function burns(item: number): boolean
	return Smelting.fuel(item) > 0 and Items.craftingRemainder(item) == nil
end

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
	end
end

return Core.define("stove", {
	fuelOnly = true,
	slots = { { x = 80, y = 53, accepts = burns } },
	fields = { "burnTime", "burnTotal", "on", "heat", "state" },
	keep = { "burnTime", "burnTotal" },
	defaults = { on = 1 },
	state = "state",
	panel = {
		flame = { x = 80, y = 36, value = "burnTime", total = "burnTotal" },
		status = { x = 8, y = 20 },
	},
	buttons = {
		{ id = HeatStates.BUTTON_MODE, x = 124, y = 52, w = 40, h = 14, label = "On/Off" },
	},
	onButton = onButton,
	tick = tick,
	status = function(view: Core.View): string?
		return HeatStates.name(view.state)
	end,
	info = {
		heat = HEAT.WoodStove,
		burnFactor = HEAT.StoveBurnFactor,
	},
})
