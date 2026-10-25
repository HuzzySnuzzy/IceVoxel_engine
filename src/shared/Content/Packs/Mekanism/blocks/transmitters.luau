--!strict
--[[
	Mekanism's transmitters and fluid tanks (Shared/Transmitters; the tier numbers are in
	Transmitters/Tiers): Logistical Transporters (items), the Restrictive Transporter and Mechanical
	Pipes (water), Basic to Ultimate, Basic to Ultimate Fluid Tanks, and Universal Cables (energy;
	Shared/Machines' energy networks).

	  * A transmitter's `shape` is Mekanism's 8 x 8 x 8 pixel core (Content/Define's `transmitter`):
	    a glass cube in a frame of twelve edges in its tier's colour (Basic dark grey, Advanced red,
	    Elite dark aqua, Ultimate purple; the Restrictive Transporter orange; Mechanical Pipes have
	    bluish grey glass). The arms towards what it connects to depend on the neighbours and the
	    configured sides, so the client draws them over the block (Rendering/TransmitterRenderer),
	    as it draws the items and water inside. Transmitters are aimed at over their whole cell
	    (`bounds`), which makes choosing a side with the Configurator easy. They are not `solid`,
	    as lanterns: the movement hull only knows full cubes, so players walk through them
	    (Mekanism's have a collision box), but they `obstruct`, so none is placed inside a player
	    and falling sand lands on them. They break fast (hardness 1, Mekanism's) and drop
	    themselves. Mekanism's Restrictive Transporter is a basic one that paths avoid.
	  * Fluid tanks (`tank`) are solid cubes: steel plates at the top and bottom, posts in the
	    tier's colour at the corners and glass sides, through which the client's water shows. What
	    a tank holds is lost when it is broken (items carry no data).
	  * A Universal Cable (`cable`) is Mekanism's small transmitter: a 6 pixel core (Mekanism's
	    5..11 box), a red-ish conductor in a frame of twelve edges in the tier's colour. Like every
	    transmitter it is aimed at over its whole cell, not solid but obstructing, breaks fast and
	    drops itself; the client draws its arms (thinner than a pipe's) towards the cables and
	    energy blocks it joins.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
-- (Pure data that requires nothing, so Blocks never depends on the Transmitters logic.)
local Tiers = require(script.Parent.Parent.Parent.Parent.Parent.Transmitters.Tiers)

type BlockSpec = Schema.BlockSpec

local TIER_NAMES = { "Basic", "Advanced", "Elite", "Ultimate" }
local TRANSPORTER_GLASS = { 206, 222, 230 }
local PIPE_GLASS = { 124, 148, 172 }
local RESTRICTIVE = { 226, 128, 40 }

return function(define: Define.Context): { BlockSpec }
	local list: { BlockSpec } = {}
	for tier, name in TIER_NAMES do
		table.insert(
			list,
			define.transmitter({
				name = `{name}LogisticalTransporter`,
				transmitter = { kind = "item", tier = tier },
			}, Tiers.TIERS[tier].colour, TRANSPORTER_GLASS)
		)
	end
	table.insert(
		list,
		define.transmitter({
			name = "RestrictiveTransporter",
			transmitter = { kind = "item", tier = 1, restrictive = true },
		}, RESTRICTIVE, TRANSPORTER_GLASS)
	)
	for tier, name in TIER_NAMES do
		table.insert(
			list,
			define.transmitter({
				name = `{name}MechanicalPipe`,
				transmitter = { kind = "fluid", tier = tier },
			}, Tiers.TIERS[tier].colour, PIPE_GLASS)
		)
	end
	for tier, name in TIER_NAMES do
		table.insert(
			list,
			define.tank({
				name = `{name}FluidTank`,
				tank = { tier = tier, capacity = Tiers.TIERS[tier].tankCapacity },
			}, Tiers.TIERS[tier].colour)
		)
	end
	for tier, name in TIER_NAMES do
		table.insert(
			list,
			define.cable({
				name = `{name}UniversalCable`,
				transmitter = { kind = "energy", tier = tier },
			}, Tiers.TIERS[tier].colour)
		)
	end
	return list
end
