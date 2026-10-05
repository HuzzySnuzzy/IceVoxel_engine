--!strict
--[[
	Mekanism Generators' Solar Generator (kind "solar"), named the Solar Panel: BlockList
	`SolarPanel`, `energy = { capacity = 96 000 J, output = 100 J/t }` (Mekanism's storage, and an
	output twice what it makes, so a network takes all of it).

	It makes energy while it sees the sun (Mekanism's WorldUtils.canSeeSun):
	  sky   nothing opaque in any cell straight above it, up to the top of the world (Minecraft's
	        canSeeSky, which wants the full sky light: glass, torches, cables and other panels let
	        the light through, leaves and ice don't; water does here, though in Minecraft it dims
	        the sky light). The server answers it (TickContext `sky`, cached per cell and looked
	        at again when a block above changes; server Machines/SkyCheck).
	  day   Minecraft's Level.isDay (DayCycle.isDay): the sky darkens by less than 4, from a little
	        after sunrise to a little before sunset, on the server's clock (World/TimeOfDay).
	Then it makes PEAK J/t (Mekanism's solarGeneration, 50) x the sun's brightness
	(DayCycle.sunBrightness, Mekanism's getSunBrightness: 1 while the sun stands more than about 24
	degrees high, falling to under half just before it stops), at most its room: a full panel waits.
	Mekanism's biome factor (hot and wet biomes make less) and rain don't apply: the game has
	neither climate numbers like Minecraft's nor weather.

	Upgrade cards (the user's ask; Mekanism's solar generators take none), Machines/Upgrades:
	  speed   Speed Upgrades raise what it makes and gives out by 10^(speed/8): 8 make 500 J/t at
	          noon and give out up to 1 000 J/t
	  energy  Energy Upgrades raise its store by 10^(energy/8): 8 hold 960 kJ
	Slots: 1 Speed Upgrades, 2 Energy Upgrades (up to 8 each, by hand and shift-click), at (8, 53)
	and (26, 53) on its panel, as the Electric Furnace's.

	Data after the header (Shared/Machines): `state`, why it makes nothing (the state code WAILA
	gets): PRODUCING (0: it makes energy; also a panel not ticked yet), NIGHT, NO_SKY or FULL (it
	sees the sun but its store is full). RATE is what it made this tick, ACTIVE is 1 while it makes
	anything (Mekanism's active: it sees the sun and has room). Its status (WAILA, the panel):
	"Producing 37.5 J/t", "Full", "Night", "No sky", or "Idle" before its first tick. Only its
	energy is kept in its item when broken; its upgrade cards drop, so placed again it holds at
	most 96 kJ of it (the rest is lost, as a smaller store loses it).

	Its panel: the status line, the upgrade slots and the energy bar.
]]

local Core = require(script.Parent.Parent.Core)
local Upgrades = require(script.Parent.Parent.Upgrades)
local DayCycle = require(script.Parent.Parent.Parent.DayCycle)
local Items = require(script.Parent.Parent.Parent.Items)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container

-- J/t made in full sun (Mekanism Generators' solarGeneration).
local PEAK = 50

-- Slots.
local SPEED, ENERGY = 1, 2

-- State codes (the `state` field; Shared/Machines KindSpec `state`).
local PRODUCING, NIGHT, NO_SKY, FULL = 0, 1, 2, 3

-- The Speed Upgrades installed (what it makes and gives out) and the Energy Upgrades (its store).
local function counts(container: Container): (number, number)
	return Upgrades.counts(container, SPEED, ENERGY)
end

local function tick(container: Container, ctx: Core.TickContext)
	local speed, energy = counts(container)
	Upgrades.setCapacity(container, Upgrades.capacity(ctx.energy.capacity, energy))
	local sky = ctx.sky
	local made, state = 0, PRODUCING
	if sky and not sky(ctx.x, ctx.y, ctx.z) then
		state = NO_SKY
	elseif not DayCycle.isDay(ctx.dayTime) then
		state = NIGHT
	else
		local production = Upgrades.production(PEAK, speed) * DayCycle.sunBrightness(ctx.dayTime)
		made = Core.produce(container, production)
		if made <= 0 then
			state = FULL
		end
	end
	Core.set(container, "state", state)
	Core.set(container, "rate", made)
	Core.set(container, "active", if made > 0 then 1 else 0)
end

return Core.define("solar", {
	slots = Upgrades.slots(8, 53),
	fields = { "state" },
	state = "state",
	panel = {
		status = { x = 8, y = 20 },
	},
	tick = tick,
	-- Twice what it makes at most, as Mekanism's (so Speed Upgrades raise it too).
	rates = function(container: Container, energy: Core.EnergySpec): (number, number)
		local speed = counts(container)
		return 0, Upgrades.production(energy.output or 0, speed)
	end,
	status = function(view: Core.View): string?
		if view.rate > 0 then
			return `Producing {Items.formatEnergy(view.rate)}/t`
		elseif view.state == NO_SKY then
			return "No sky"
		elseif view.state == NIGHT then
			return "Night"
		elseif view.state == FULL then
			return "Full"
		end
		return "Idle"
	end,
})
