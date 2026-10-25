--!strict
--[[
	The zombie apocalypse's blocks (Generation/Cities, Generation/Bunkers, server Apocalypse/). Each
	sets its own blast resistance, fire odds and zombie break time (`zombieBreak`, ticks for one
	ordinary zombie: server Mobs/MobAI; asphalt and bricks 2400, a barricade 900, a reinforced one
	3000, concrete 6000; the rusty metal, the containers, the bunker hatch and the lamp never), and
	its texture, lore and Age, on the block that is the item: the barricades along Z and the shut
	hatch (their textures cover the turned barricades and the open hatch too), the lamp and not its
	cave twin (a light: never textured). The Reinforced Barricade, the Bunker Hatch and the Ceiling
	Lamp are the Iron Age's, Concrete (cracked and mossy too: the results are gated, not the
	inputs) the Industrial Age's, the rest the Stone Age's.

	  * The ruins: Asphalt, Cracked Asphalt and the two painted road lines (Road Line on top: white,
	    Yellow Road Line: the centre line; their sides and bottoms are asphalt), only found, never
	    crafted. Concrete (sand and gravel; the ruins' walls and the bunkers' shells), Cracked
	    Concrete (smelted Concrete), Mossy Concrete (with a Vine), Cracked and Mossy Bricks
	    (likewise from Bricks). Rusty Metal, the wrecks' corroded steel, breaks up into three Scrap
	    Metal. The Supply Crate (a stocked wooden crate) and the Medicine Cabinet (a steel cabinet
	    for bandages and pills) are 27 slot chests the ruins and bunkers fill with the pack's loot.
	  * Barricades: three boards nailed over two battens, the Reinforced Barricade with two strips
	    of scrap steel behind them (the pack's _shapes). Solid (their whole cell collides) but drawn
	    as boards, nothing hangs on them, and placing picks the one along the player's facing
	    (`axis`, as rails: Barricade spans East-West in front of a player facing North or South,
	    BarricadeNorthSouth the other way); a draughty wall (`insulation` 0.15).
	  * The Bunker Hatch: a steel plate lying flush on the cell's floor over a ladder shaft (closed:
	    3 pixels high, walked over), turned up against the north side when open (BunkerHatchOpen).
	    Right clicking swaps the two (`menu` "Toggle", `toggle`; server Players/ToggleUse, which
	    plays its sound for everyone). Zombies never break it: a closed bunker is safe.
	  * The Ceiling Lamp: a caged lamp hanging under a sturdy block (`support` Up), light 14; the
	    bunkers hang its cave twin (CaveCeilingLamp) in cave air.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local shapes = require(script.Parent._shapes)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox

local ASPHALT = { 54, 56, 60 }
local BOARDS = { 150, 116, 74 }
local HATCH = { 92, 96, 90 }

return function(define: Define.Context): { BlockSpec }
	local list: { BlockSpec } = {
		{
			name = "Asphalt",
			color = ASPHALT,
			material = "Asphalt",
			sound = "stone",
			hardness = 1.5,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 3,
			zombieBreak = 2400,
			texture = { All = "asphalt" },
			lore = "Old road surface. Holds the summer heat long after the cars stopped.",
		},
		{
			name = "CrackedAsphalt",
			displayName = "Cracked Asphalt",
			color = { 68, 68, 70 },
			material = "Asphalt",
			sound = "stone",
			hardness = 1.2,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 3,
			zombieBreak = 2400,
			texture = { All = "cracked asphalt" },
			lore = "Road broken by roots and frost. Nobody came to fix it.",
		},
		{
			name = "RoadLine",
			displayName = "Road Line",
			color = { 222, 222, 212 },
			material = "Asphalt",
			sound = "stone",
			hardness = 1.5,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 3,
			zombieBreak = 2400,
			texture = { Top = "road line", Sides = "asphalt", Bottom = "asphalt" },
			lore = "A faded white lane line nobody follows any more.",
		},
		{
			name = "RoadLineYellow",
			displayName = "Yellow Road Line",
			color = { 214, 178, 58 },
			material = "Asphalt",
			sound = "stone",
			hardness = 1.5,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 3,
			zombieBreak = 2400,
			texture = { Top = "road line yellow", Sides = "asphalt", Bottom = "asphalt" },
			lore = "Yellow paint: do not cross. Nobody is left to mind.",
		},
	}
	for _, concrete in
		{
			{
				name = "Concrete",
				color = { 168, 168, 162 },
				hardness = 1.8,
				texture = { All = "concrete" },
				lore = "Poured stone that cities were built of. Gravel and sand make it.",
			},
			{
				name = "CrackedConcrete",
				color = { 150, 150, 144 },
				hardness = 1.5,
				texture = { All = "cracked concrete" },
				lore = "Concrete giving up, one crack at a time. Smelt Concrete for it.",
			},
			{
				name = "MossyConcrete",
				color = { 122, 140, 100 },
				hardness = 1.8,
				texture = { All = "mossy concrete" },
				lore = "Concrete with Vines worked into it: the ruins' green.",
			},
		}
	do
		table.insert(list, {
			name = concrete.name,
			color = concrete.color,
			material = "Concrete",
			sound = "stone",
			hardness = concrete.hardness,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 6,
			zombieBreak = 6000,
			texture = concrete.texture,
			lore = concrete.lore,
			age = "industrial",
		})
	end
	for _, brick in
		{
			{
				name = "CrackedBricks",
				color = { 140, 74, 60 },
				texture = { All = "cracked bricks" },
				lore = "Bricks split by weather and neglect. Smelt Bricks for them.",
			},
			{
				name = "MossyBricks",
				color = { 112, 108, 74 },
				texture = { All = "mossy bricks" },
				lore = "Old brickwork wearing a coat of moss. Bricks and Vines make it.",
			},
		}
	do
		table.insert(list, {
			name = brick.name,
			color = brick.color,
			material = "Brick",
			sound = "stone",
			hardness = 2,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 6,
			zombieBreak = 2400,
			texture = brick.texture,
			lore = brick.lore,
		})
	end
	define.append(list, {
		{
			name = "RustyMetal",
			displayName = "Rusty Metal",
			color = { 128, 80, 52 },
			material = "CorrodedMetal",
			sound = "metal",
			hardness = 3,
			tool = "pickaxe",
			toolLevel = 0,
			blastResistance = 6,
			drops = "ScrapMetal" :: string,
			dropCount = 3,
			texture = { All = "rusty metal" },
			lore = "Corroded sheet steel. Breaks up into Scrap Metal.",
		},
		{
			name = "SupplyCrate",
			displayName = "Supply Crate",
			color = { 150, 112, 70 },
			material = "WoodPlanks",
			sound = "wood",
			hardness = 2.5,
			tool = "axe",
			blastResistance = 2.5,
			container = 27,
			menu = "Chest",
			flammable = { ignite = 5, burn = 20 },
			texture = { Top = "supply crate top", Sides = "supply crate side", Bottom = "supply crate top" },
			lore = "A wooden crate someone stocked and never came back for.",
		},
		{
			name = "MedicineCabinet",
			displayName = "Medicine Cabinet",
			color = { 226, 228, 226 },
			material = "Metal",
			sound = "metal",
			hardness = 2,
			tool = "pickaxe",
			blastResistance = 2,
			container = 27,
			menu = "Chest",
			texture = { Top = "medicine cabinet top", Sides = "medicine cabinet side" },
			lore = "Check it for bandages and pills before anyone else does.",
		},
	})

	-- Barricades, along each axis (the one along Z is the item: its lore and Age).
	for _, barricade: { reinforced: boolean, lore: string, age: string? } in
		{
			{ reinforced = false, lore = "Boards nailed across a gap. Zombies take a while to break it." },
			{ reinforced = true, lore = "Boards and scrap steel. The dead will be at it a long time.", age = "iron" },
		}
	do
		local reinforced = barricade.reinforced
		local base = if reinforced then "ReinforcedBarricade" else "Barricade"
		for _, axis in { "Z", "X" } do
			local turned = axis == "X"
			table.insert(list, {
				name = if turned then base .. "NorthSouth" else base,
				displayName = if reinforced then "Reinforced Barricade" else "Barricade",
				color = BOARDS,
				material = "WoodPlanks",
				sound = "wood",
				solid = true,
				sturdy = false,
				placeable = not turned,
				item = if turned then base else nil,
				hardness = if reinforced then 4 else 2,
				tool = "axe",
				blastResistance = if reinforced then 6 else 2,
				shape = shapes.barricade(axis, reinforced),
				bounds = { min = { 0, 0, 0 }, max = { 16, 16, 16 } },
				axis = axis,
				flammable = if reinforced then { ignite = 5, burn = 5 } else { ignite = 5, burn = 20 },
				-- (Boards with gaps: a draughty wall.)
				insulation = 0.15,
				zombieBreak = if reinforced then 3000 else 900,
				texture = if turned then nil else { All = "planks" },
				lore = if turned then nil else barricade.lore,
				age = if turned then nil else barricade.age,
			})
		end
	end

	-- The Bunker Hatch, shut (lying on the floor) and open (up against the north side).
	for _, open in { false, true } do
		table.insert(list, {
			name = if open then "BunkerHatchOpen" else "BunkerHatch",
			displayName = "Bunker Hatch",
			color = HATCH,
			material = "DiamondPlate",
			sound = "metal",
			solid = false,
			collides = true,
			placeable = not open,
			item = if open then "BunkerHatch" else nil,
			hardness = 5,
			tool = "pickaxe",
			toolLevel = 1,
			blastResistance = 6,
			shape = if open
				then {
					{ size = { 16, 16, 3 }, offset = { 0, 0, -6.5 } },
					{ size = { 4, 1, 1 }, offset = { 0, -4, -4.5 }, color = { 60, 62, 60 } },
				}
				else {
					{ size = { 16, 3, 16 }, offset = { 0, -6.5, 0 } },
					{ size = { 4, 1, 1 }, offset = { 0, -4.5, 4 }, color = { 60, 62, 60 } },
				},
			bounds = if open then define.wallBounds("North", 3) else { min = { 0, 0, 0 }, max = { 16, 3, 16 } },
			collision = if open then nil else { { min = { 0, 0, 0 }, max = { 16, 3, 16 } } },
			menu = "Toggle",
			toggle = if open
				then { to = "BunkerHatch", sound = "block.bunker_hatch.close" }
				else { to = "BunkerHatchOpen", sound = "block.bunker_hatch.open" },
			-- (Shut, a steel floor face; open, the shaft's air flows through.)
			insulation = if open then nil else 0.06,
			texture = if open then nil else { All = "bunker hatch" },
			lore = if open then nil else "A steel hatch over a ladder shaft. The dead can't break it.",
			age = if open then nil else "iron",
		})
	end

	-- The Ceiling Lamp: a steel housing under the ceiling and its glowing lamp below; and its cave
	-- twin.
	local lampShape: { ShapeBox } = {
		{ size = { 4, 2, 4 }, offset = { 0, 5, 0 }, color = { 255, 236, 200 }, material = "Neon", glow = true },
		{ size = { 6, 2, 6 }, offset = { 0, 7, 0 } },
	}
	local lamp: BlockSpec = {
		name = "CeilingLamp",
		displayName = "Ceiling Lamp",
		color = { 70, 72, 74 },
		material = "Metal",
		sound = "metal",
		solid = false,
		placeable = true,
		hardness = 0.5,
		tool = "pickaxe",
		blastResistance = 0.5,
		light = 14,
		lightColor = { 255, 236, 200 },
		shape = lampShape,
		bounds = { min = { 5, 12, 5 }, max = { 11, 16, 11 } },
		support = "Up",
		behaviour = "Attached",
		brokenByFluid = true,
		lore = "A caged lamp that hangs from the ceiling. Still glowing.",
		age = "iron",
	}
	table.insert(list, lamp)
	-- (The twin's item is the lamp: the lore and the Age are the lamp's alone.)
	local twin = define.caveTwin(lamp)
	twin.lore, twin.age = nil, nil
	table.insert(list, twin)
	return list
end
