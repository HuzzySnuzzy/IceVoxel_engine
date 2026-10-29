--!strict
--[[
	Mekanism's machines and generators (Shared/Machines; the server runs them in server/Machines):
	the Creative Energy Cube, the Heat Generator, the Electric Furnace, the Solar Panel and the
	Batteries. Mekanism's machine block: hardness 3.5, mined fast with a pickaxe, which it needs to
	drop anything (the creative cube: hardness 2, no tool needed), metal sounds, drawn with its
	BlockDecor faces (never textured); zombies never break them.

	  * The Creative Energy Cube is Mekanism's: infinite energy, given out without limit, creative
	    only (no recipe). A cube of dark steel with a magenta frame (BlockDecor
	    "CreativeEnergyCube").
	  * Mekanism Generators' Heat Generator (Machines/Kinds/Generator, kind "generator"): burns
	    furnace fuel, 200 J a tick of burning, into Mekanism's 160 000 J store, given out at up to
	    400 J/t (twice what it makes) to cables and machines touching it. A dark steel casing with
	    grilles and a fuel window (BlockDecor "HeatGenerator"; the client lights the window while
	    it burns, Rendering/TransmitterModel.machineBoxes).
	  * Mekanism's Energized Smelter, named the Electric Furnace (Machines/Kinds/Smelter, kind
	    "smelter"): smelts what a furnace smelts on 50 J a tick of work, 200 ticks an item, from
	    Mekanism's 20 000 J store, which cables and machines touching it may fill in a single
	    tick. A light steel casing with osmium bolts and a heating chamber window (BlockDecor
	    "ElectricFurnace").
	  * Mekanism Generators' Solar Generator, named the Solar Panel (Machines/Kinds/Solar, kind
	    "solar"): makes up to 50 J a tick while the sky straight above it is open and it is day
	    (more with Speed Upgrades), into Mekanism's 96 000 J store (more with Energy Upgrades),
	    given out at up to 100 J/t (twice what it makes). Mekanism's model is no full cube either: a
	    thin panel of four dark blue cells in a steel frame on a short post over a foot, 9 pixels
	    tall. Like a lantern it is not solid but obstructs (the movement hull only knows full
	    cubes); it is no opaque block, so the panels of a stack all see the sky.
	  * Mekanism's Energy Cubes, named Batteries (Machines/Kinds/Battery, kind "battery"), Basic to
	    Ultimate: Mekanism's EnergyCubeTier stores (4, 16, 64 and 256 MJ) and rates (4, 16, 64 and
	    256 kJ/t), the same in and out (Transmitters/Tiers), so they are storage: the energy
	    networks charge them with what generators have left over and draw on them when generators
	    fall short, the backup. Its item keeps its charge, so it stacks to 1 (Mekanism's energy
	    cubes do). A dark steel cube with corners in the tier's colour (Mekanism's energy cube
	    frame), a charge gauge on each side and a terminal on top (BlockDecor "<Tier>Battery"; the
	    client fills the gauges from the machine's record, Rendering/TransmitterModel.machineBoxes).
	  * Ages: the Heat Generator is the Industrial Age's (entering the Electric Age takes one),
	    the Electric Furnace and the Basic and Advanced Batteries the Electric Age's, the Solar
	    Panel and the Elite and Ultimate Batteries the Atomic Age's. The Batteries are a list of
	    their tiers, Basic to Ultimate: each row is one tier's name, lore and Age, and the loop
	    under it makes the tier's entry of it.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local Tiers = require(script.Parent.Parent.Parent.Parent.Parent.Transmitters.Tiers)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox

local STEEL = { 112, 116, 124 }
local SOLAR_CELL = { 28, 46, 104 }

return function(define: Define.Context): { BlockSpec }
	local metalBox = define.metalBox
	local solarShape: { ShapeBox } = {
		metalBox({ 6, 1, 6 }, { 0, -7.5, 0 }, STEEL),
		metalBox({ 2, 6, 2 }, { 0, -4, 0 }, STEEL),
		metalBox({ 16, 1, 16 }, { 0, -0.5, 0 }, { 84, 88, 96 }),
	}
	for _, x in { -3.75, 3.75 } do
		for _, z in { -3.75, 3.75 } do
			table.insert(
				solarShape,
				{ size = { 7, 1, 7 }, offset = { x, 0.5, z }, color = SOLAR_CELL, material = "Glass", transparency = 0 }
			)
		end
	end
	local list: { BlockSpec } = {
		{
			name = "CreativeEnergyCube",
			color = { 40, 38, 46 },
			material = "Metal",
			sound = "metal",
			hardness = 2,
			tool = "pickaxe",
			decor = "CreativeEnergyCube",
			machine = { kind = "creative" },
			energy = { capacity = math.huge, output = math.huge },
			lore = "Never runs out of energy. Creative only.",
			-- (Each machine is a point of interest /locate poi finds: Shared/Poi.)
			poi = "energy_cube",
		},
		{
			name = "HeatGenerator",
			color = { 62, 64, 70 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "HeatGenerator",
			machine = { kind = "generator" },
			energy = { capacity = 160000, output = 400 },
			lore = "Burns furnace fuel or lava for energy. Lava around it helps.",
			age = "industrial",
			poi = "heat_generator",
			-- (Working, it warms a room's air by 10 HU a second: the seasons' rooms.)
			roomHeat = { hu = 10 },
		},
		{
			name = "ElectricFurnace",
			color = { 150, 154, 162 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "ElectricFurnace",
			machine = { kind = "smelter" },
			energy = { capacity = 20000, input = 20000 },
			workSound = "block.electric_furnace.hum",
			lore = "Smelts with energy instead of fuel. Takes upgrades.",
			age = "electric",
			poi = "electric_furnace",
		},
		{
			name = "SolarPanel",
			color = SOLAR_CELL,
			material = "Metal",
			sound = "metal",
			solid = false,
			placeable = true,
			obstructs = true,
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			shape = solarShape,
			machine = { kind = "solar" },
			energy = { capacity = 96000, output = 100 },
			lore = "Makes energy under an open sky by day.",
			age = "atomic",
			poi = "solar_panel",
		},
	}
	local batteries = {
		{ name = "BasicBattery", lore = "Stores energy, and keeps it when broken.", age = "electric" },
		{ name = "AdvancedBattery", lore = "A bigger battery that keeps its charge.", age = "electric" },
		{ name = "EliteBattery", lore = "A large battery that keeps its charge.", age = "atomic" },
		{ name = "UltimateBattery", lore = "The largest battery there is.", age = "atomic" },
	}
	for tier, own in batteries do
		local numbers = Tiers.TIERS[tier]
		table.insert(list, {
			name = own.name,
			color = { 52, 54, 60 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			maxStack = 1,
			decor = own.name,
			machine = { kind = "battery" },
			energy = { capacity = numbers.batteryCapacity, input = numbers.batteryRate, output = numbers.batteryRate },
			lore = own.lore,
			age = own.age,
			-- (Every tier is one point of interest.)
			poi = "battery",
		})
	end
	return list
end
