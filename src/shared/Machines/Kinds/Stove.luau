--!strict
--[[
	The Wood Stove (kind "stove", fuel only: BlockList `WoodStove`, `energy = { capacity = 0 }`):
	burns furnace fuel (Crafting/Smelting.fuel, anything that leaves nothing behind) for
	Config.Seasons.Heat.StoveBurnFactor times its furnace burn time (a coal 320 s, a log 60 s),
	giving WoodStove HU to the room it stands in while it burns (server Seasons/RoomWorld reads
	`heat`), and radiant warmth (Players/Climate: in a room or out of one, like a campfire). It is
	no thermostat: on, it burns. Switched off it holds its fuel (what burns stays half burnt).

	Each tick, on: with nothing burning the next item in its slot lights (one is used up, its
	burn time x StoveBurnFactor ticks), then what burns burns a tick for WoodStove HU; with nothing
	to burn, nothing ("No fuel"). A new item lights in the tick after the last one ran out, so the
	fire never dips between two.

	Data after the header (Shared/Machines), frozen (saved items depend on it):
	  burnTime   ticks left of what burns (kept in the item; at most the longest fuel's)
	  burnTotal  that item's burn ticks (the flame's full height; kept in the item)
	  on         1 on (a fresh stove's), 0 off (the Mode button: holds the fuel)
	  heat       HU delivered last tick
	  state      Seasons/HeatStates code: HEATING, NO_FUEL, OFF
	RATE is the HU it gives this tick (it holds no energy, so the header's rate carries the heat
	for WAILA: "Heating 30 HU"), ACTIVE 1 while it burns (its window glows, its light is on, it
	crackles). One fuel slot under the furnace's flame; the "On/Off" button (BUTTON_MODE). No
	energy: no energy bar, cables never connect.
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Items = require(script.Parent.Parent.Parent.Items)
local Smelting = require(script.Parent.Parent.Parent.Crafting.Smelting)
local HeatStates = require(script.Parent.Parent.Parent.Seasons.HeatStates)
local Rooms = require(script.Parent.Parent.Parent.Seasons.Rooms)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

local HEAT = Config.Seasons.Heat
local FACTOR = HEAT.StoveBurnFactor
local FUEL = 1

-- Does `item` burn in the stove (a furnace fuel that leaves nothing behind)?
local function burns(item: number): boolean
	return Smelting.fuel(item) > 0 and Items.craftingRemainder(item) == nil
end

-- The longest anything burns here (ticks): no burn field goes above it.
local MAX_BURN = 0
for _, fuel in Smelting.fuels() do
	if burns(fuel.item) then
		MAX_BURN = math.max(MAX_BURN, fuel.ticks * FACTOR)
	end
end

-- Lights the next item in the slot (one used up): its burn ticks here, 0 when none.
local function light(container: Container): number
	local stack = container.slots[FUEL]
	if stack == nil or stack.count < 1 or not burns(stack.item) then
		return 0
	end
	container.slots[FUEL] = Items.withCount(stack, stack.count - 1)
	return math.min(Smelting.fuel(stack.item) * FACTOR, MAX_BURN)
end

local function tick(container: Container, _ctx: Core.TickContext)
	local burn = math.clamp(Core.get(container, "burnTime"), 0, MAX_BURN)
	local total = math.clamp(Core.get(container, "burnTotal"), 0, MAX_BURN)
	local heat, state = 0, HeatStates.IDLE
	if Core.get(container, "on") == 0 then
		state = HeatStates.OFF
	else
		if burn <= 0 then
			burn = light(container)
			total = burn
		end
		if burn > 0 then
			burn = math.max(burn - 1, 0)
			heat, state = HEAT.WoodStove, HeatStates.HEATING
		else
			total, state = 0, HeatStates.NO_FUEL
		end
	end
	Core.set(container, "burnTime", burn)
	-- (The flame never shows more than full.)
	Core.set(container, "burnTotal", if burn > 0 then math.max(total, burn) else total)
	Core.set(container, "heat", heat)
	Core.set(container, "rate", heat)
	Core.set(container, "state", state)
	Core.set(container, "active", if heat > 0 then 1 else 0)
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
		if view.state == HeatStates.HEATING then
			return `Heating {Rooms.huText(view.rate)} HU`
		end
		return HeatStates.name(view.state)
	end,
	info = {
		heat = HEAT.WoodStove,
		burnFactor = FACTOR,
		maxBurn = MAX_BURN,
	},
})
