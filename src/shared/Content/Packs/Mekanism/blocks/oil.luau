--!strict
--[[
	Oil and fuel: BuildCraft's oil and the fuel the Oil Refinery makes of it, fluid groups like water
	(Content/Define's `fluid`; Shared/Fluids, server Behaviours/Fluid's rules), the oil source's
	cave twin, and the machines that make and burn the fuel. (The oil wells: Generation's.)

	  * Oil: nearly black glass that barely shows through and shines, tick delay 20 (viscous).
	    CaveOil is its source's cave twin (`caveFluid`): the oil deposits buried in rock, a source
	    in every way but cave air while caves are hidden, so a buried deposit costs nothing to draw.
	  * Fuel: translucent amber, tick delay 5 like water. The explosive itself: explosions run
	    through it (blast resistance 0; server World/Explosions sets its source off), and its
	    flowing levels burn like a fuse to the source: fire spreads over them and eats them as
	    readily as anything (100 / 100).
	  * The Oil Refinery (Machines/Kinds/Refinery, kind "refinery"): BuildCraft's refinery on
	    electricity, turning oil into fuel 1:1 at 10 mB a tick for 200 J a tick (a bucket in 100
	    ticks for 20 kJ; Speed and Energy Upgrades with Mekanism's maths), from Mekanism-sized tanks
	    of 10 000 mB each and a 40 000 J store, which cables and machines touching it may fill in a
	    single tick. A light steel casing with an oil and a fuel sight glass on each side and two
	    tank caps on top (BlockDecor "OilRefinery"; the client may light its heater window while it
	    works, REFINERY_WINDOW).
	  * The Combustion Generator (Machines/Kinds/Combustion, kind "combustion"): burns the
	    refinery's fuel at 2 500 J a tick, a mB every 4 ticks (a bucket is 4 000 ticks, 10 MJ), from
	    a 10 000 mB fuel tank into a 1 MJ store, given out at up to 5 kJ/t (twice what it makes) to
	    cables and machines touching it. A dark steel casing with amber fuel stripes, a combustion
	    chamber window low on each side and an exhaust on top (BlockDecor "CombustionGenerator";
	    the client may light the window while it burns, COMBUSTION_WINDOW).
	  Both are Mekanism's machine block: hardness 3.5, a pickaxe to drop anything.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec

return function(define: Define.Context): { BlockSpec }
	local list: { BlockSpec } = {}
	local oil = define.fluid("Oil", {
		name = "Oil",
		color = { 24, 22, 26 },
		material = "Glass",
		transparency = 0.1,
		reflectance = 0.2,
	}, 20)
	define.append(list, oil)
	define.append(
		list,
		define.fluid("Fuel", {
			name = "Fuel",
			color = { 232, 172, 44 },
			material = "Glass",
			transparency = 0.4,
			reflectance = 0.05,
			blastResistance = 0,
		}, 5, { flammable = { ignite = 100, burn = 100 } })
	)
	table.insert(list, define.caveFluid(oil[1]))
	define.append(list, {
		{
			name = "OilRefinery",
			color = { 140, 144, 152 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "OilRefinery",
			machine = { kind = "refinery" },
			energy = { capacity = 40000, input = 40000 },
		},
		{
			name = "CombustionGenerator",
			color = { 56, 58, 64 },
			material = "Metal",
			sound = "metal",
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			decor = "CombustionGenerator",
			machine = { kind = "combustion" },
			energy = { capacity = 1000000, output = 5000 },
		},
	})
	return list
end
