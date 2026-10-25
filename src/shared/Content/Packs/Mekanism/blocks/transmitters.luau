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
	    a tank holds stays in its item when a survival player breaks it (Mekanism's sustained data:
	    server Transmitters/TransmitterWorld), and is lost otherwise.
	  * A Universal Cable (`cable`) is Mekanism's small transmitter: a 6 pixel core (Mekanism's
	    5..11 box), a red-ish conductor in a frame of twelve edges in the tier's colour. Like every
	    transmitter it is aimed at over its whole cell, not solid but obstructing, breaks fast and
	    drops itself; the client draws its arms (thinner than a pipe's) towards the cables and
	    energy blocks it joins.
	  * Ages: Basic and Advanced transporters, pipes and tanks (and the Restrictive Transporter)
	    are the Industrial Age's, Elite ones the Electric Age's, Ultimate ones the Atomic Age's;
	    cables come an Age later, with the machines they feed (Basic and Advanced the Electric
	    Age's, Elite and Ultimate the Atomic Age's).

	Each kind is a list of its tiers, Basic to Ultimate: each row is one tier's entry (its name,
	lore and Age), and the loop under the list adds its tier and its shape (Content/Define's
	`transmitter`, `tank` and `cable`).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
-- (Pure data that requires nothing, so Blocks never depends on the Transmitters logic.)
local Tiers = require(script.Parent.Parent.Parent.Parent.Parent.Transmitters.Tiers)

type BlockSpec = Schema.BlockSpec

local TRANSPORTER_GLASS = { 206, 222, 230 }
local PIPE_GLASS = { 124, 148, 172 }
local RESTRICTIVE = { 226, 128, 40 }

return function(define: Define.Context): { BlockSpec }
	local list: { BlockSpec } = {}
	local transporters: { BlockSpec } = {
		{
			name = "BasicLogisticalTransporter",
			lore = "Moves items between inventories. Configure sides to push or pull.",
			age = "industrial",
		},
		{
			name = "AdvancedLogisticalTransporter",
			lore = "A faster transporter that pulls bigger stacks.",
			age = "industrial",
		},
		{ name = "EliteLogisticalTransporter", lore = "An even faster transporter.", age = "electric" },
		{ name = "UltimateLogisticalTransporter", lore = "The fastest transporter there is.", age = "atomic" },
	}
	for tier, spec in transporters do
		spec.transmitter = { kind = "item", tier = tier }
		table.insert(list, define.transmitter(spec, Tiers.TIERS[tier].colour, TRANSPORTER_GLASS))
	end
	table.insert(
		list,
		define.transmitter({
			name = "RestrictiveTransporter",
			transmitter = { kind = "item", tier = 1, restrictive = true },
			lore = "Items take it only when there is no other way.",
			age = "industrial",
		}, RESTRICTIVE, TRANSPORTER_GLASS)
	)
	local pipes: { BlockSpec } = {
		{ name = "BasicMechanicalPipe", lore = "Carries fluids between tanks and machines.", age = "industrial" },
		{ name = "AdvancedMechanicalPipe", lore = "A pipe that carries more fluid.", age = "industrial" },
		{ name = "EliteMechanicalPipe", lore = "A pipe that carries a lot of fluid.", age = "electric" },
		{ name = "UltimateMechanicalPipe", lore = "The widest pipe there is.", age = "atomic" },
	}
	for tier, spec in pipes do
		spec.transmitter = { kind = "fluid", tier = tier }
		table.insert(list, define.transmitter(spec, Tiers.TIERS[tier].colour, PIPE_GLASS))
	end
	local tanks: { BlockSpec } = {
		{ name = "BasicFluidTank", lore = "Holds a fluid, and keeps it when broken.", age = "industrial" },
		{ name = "AdvancedFluidTank", lore = "A bigger fluid tank that keeps its contents.", age = "industrial" },
		{ name = "EliteFluidTank", lore = "A large fluid tank that keeps its contents.", age = "electric" },
		{ name = "UltimateFluidTank", lore = "The largest fluid tank there is.", age = "atomic" },
	}
	for tier, spec in tanks do
		spec.tank = { tier = tier, capacity = Tiers.TIERS[tier].tankCapacity }
		table.insert(list, define.tank(spec, Tiers.TIERS[tier].colour))
	end
	local cables: { BlockSpec } = {
		{
			name = "BasicUniversalCable",
			lore = "Carries energy between generators, batteries and machines.",
			age = "electric",
		},
		{ name = "AdvancedUniversalCable", lore = "A cable that carries more energy.", age = "electric" },
		{ name = "EliteUniversalCable", lore = "A cable that carries a lot of energy.", age = "atomic" },
		{ name = "UltimateUniversalCable", lore = "The thickest cable there is.", age = "atomic" },
	}
	for tier, spec in cables do
		spec.transmitter = { kind = "energy", tier = tier }
		table.insert(list, define.cable(spec, Tiers.TIERS[tier].colour))
	end
	return list
end
