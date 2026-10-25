--!strict
--[[
	Mekanism's items: the Configurator, osmium's raw lump, ingot and nugget, the upgrade cards, and
	the oil and fuel buckets.

	  * The Configurator (Mekanism's tool) sets how each side of a transmitter connects and colours
	    transporters: a wrench with a blue head and a small screen on its grip, modelled upright and
	    tilted like the tools.
	  * Mekanism's osmium: what Osmium Ore drops (Raw Osmium), the ingot it smelts into and the
	    nugget, drawn like their iron and gold counterparts in a bluish silver. Mekanism's later
	    machines and cables are made from the ingot.
	  * Mekanism's upgrade cards (Shared/Machines/Upgrades): the Speed Upgrade and the Energy
	    Upgrade, which the Electric Furnace and the Solar Panel take in their upgrade slots, 8 of
	    each at most (Mekanism's Upgrade.getMax); they stack to that 8 too (Mekanism's own stack to
	    64). A small circuit card with gold contacts and the upgrade's symbol in its colour
	    (Mekanism's EnumColor: red for speed, bright green for energy): two chevrons, a bolt (the
	    pack's _models).
	  * Buckets of oil and fuel (BuildCraft's): Minecraft's bucket (Content/Define's
	    `filledBucket`) with the fluid's colour to the rim (Shared/Fluids' colours; oil glossy).
	    They don't stack, and each leaves the empty Bucket when used up (Items.craftingRemainder).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local models = require(script.Parent._models)

local CONFIGURATOR_BLUE = { 44, 116, 214 }
local CONFIGURATOR_GRIP = { 62, 64, 72 }
local RAW_OSMIUM = { 132, 158, 190 }
local OSMIUM = { 172, 192, 216 }
local SPEED_RED = { 226, 64, 60 }
local ENERGY_GREEN = { 96, 226, 92 }
local OIL = { 24, 22, 26 }
local FUEL = { 232, 172, 44 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	local speedSymbol = models.chevron(0, 1.5)
	for _, box in models.chevron(3.5, 1.5) do
		table.insert(speedSymbol, box)
	end
	return {
		{
			name = "Configurator",
			maxStack = 1,
			color = CONFIGURATOR_BLUE,
			material = "Metal",
			model = {
				{ size = { 2, 11, 1.5 }, offset = { 0, -3.5, 0 }, color = CONFIGURATOR_GRIP },
				{ size = { 2.4, 1, 1.8 }, offset = { 0, -8.25, 0 }, color = { 30, 30, 34 } },
				{ size = { 1.2, 2, 0.4 }, offset = { 0, -1, 0.9 }, color = { 120, 230, 255 }, material = "Neon" },
				{ size = { 6, 2, 1.5 }, offset = { 0, 3, 0 }, color = shade(CONFIGURATOR_BLUE, 0.8) },
				{ size = { 2, 4, 1.5 }, offset = { -2, 6, 0 } },
				{ size = { 2, 4, 1.5 }, offset = { 2, 6, 0 } },
				{ size = { 1, 3, 1.6 }, offset = { -2.5, 6.5, 0 }, color = shade(CONFIGURATOR_BLUE, 1.2) },
			},
			tilt = -45,
		},
		{
			name = "RawOsmium",
			color = RAW_OSMIUM,
			material = "Rock",
			model = define.lump(RAW_OSMIUM, { 200, 218, 238 }, { 84, 106, 136 }),
		},
		{ name = "OsmiumIngot", color = OSMIUM, material = "Metal", model = define.ingot(OSMIUM), tilt = 25 },
		{ name = "OsmiumNugget", color = OSMIUM, material = "Metal", model = define.nugget(OSMIUM) },
		{
			name = "SpeedUpgrade",
			maxStack = 8,
			color = SPEED_RED,
			material = "Metal",
			model = models.upgradeCard(speedSymbol),
		},
		{
			name = "EnergyUpgrade",
			maxStack = 8,
			color = ENERGY_GREEN,
			material = "Metal",
			-- (A bolt: a stroke down to the left end of a bar, the bar, a stroke down from its right end.)
			model = models.upgradeCard({
				{ size = { 1.4, 4.5, 0.4 }, offset = { -0.55, 3.55, 1 }, rotation = -25, material = "Neon" },
				{ size = { 4, 1.3, 0.4 }, offset = { 0, 1.5, 1 }, material = "Neon" },
				{ size = { 1.4, 4.5, 0.4 }, offset = { 0.55, -0.55, 1 }, rotation = -25, material = "Neon" },
			}),
		},
		{
			name = "OilBucket",
			maxStack = 1,
			color = OIL,
			material = "Metal",
			model = define.filledBucket(OIL, "Glass"),
		},
		{
			name = "FuelBucket",
			maxStack = 1,
			color = FUEL,
			material = "Metal",
			model = define.filledBucket(FUEL, "SmoothPlastic"),
		},
	}
end
