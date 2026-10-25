--!strict
--[[
	What mobs drop (Shared/Entities/MobList; server Mobs/MobWorld), Minecraft 1.20.1's loot: Leather
	(cows: makes Minecraft's leather armor), raw meat (Raw Beef, Raw Mutton, Raw Porkchop, Raw
	Chicken: a mob that dies burning drops it cooked, as Minecraft's furnace_smelt loot function),
	cooked in a furnace (Steak, Cooked Mutton, Cooked Porkchop, Cooked Chicken) and eaten with the
	32 tick hold for health (Shared/Items/Foods), Feathers (chickens), Rotten Flesh (zombies:
	edible, with a likely Thirst effect), Bones (zombies now and then, and the ruins' loot), String
	(cobwebs, and the ruins' loot: four make White Wool). Pixel boxes like the other items: a ragged
	hide, slabs of meat with their fat or bone, a drumstick, a quill, a knobbed bone and a looped
	thread, as Minecraft's icons (the meat's are the pack's _models). Each carries its lore and a
	blank icon; cooked meat gives 0.35 knowledge a piece out of a furnace (Minecraft's cooked food
	experience).

	What eating the meat does is its `food`, Minecraft's numbers (Shared/Items/Foods: nutrition in
	points of the 20; saturation the modifier, in brackets what it adds; heals in half hearts with
	hunger off, about half the nutrition; each held the 32 ticks):

	  Food              nutrition  saturation  heals  risk (`effect`)
	  Steak             8          0.8 (12.8)  4      -
	  Cooked Porkchop   8          0.8 (12.8)  4      -
	  Cooked Mutton     6          0.8 (9.6)   3      -
	  Cooked Chicken    6          0.6 (7.2)   3      -
	  Raw Beef          3          0.3 (1.8)   2      -
	  Raw Porkchop      3          0.3 (1.8)   2      -
	  Raw Mutton        2          0.3 (1.2)   1      -
	  Raw Chicken       2          0.3 (1.2)   1      30%: Hunger for 30 s
	  Rotten Flesh      4          0.1 (0.8)   2      80%: Hunger for 30 s
	(Minecraft's Hunger effect with hunger on, as Minecraft's raw chicken and rotten flesh bring;
	Tough As Nails' Thirst effect with it off.)
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

local LEATHER = { 150, 88, 52 }
local FAT = { 236, 226, 214 }
local RAW_BEEF = { 196, 52, 52 }
local STEAK = { 120, 66, 38 }
local RAW_MUTTON = { 206, 70, 66 }
local COOKED_MUTTON = { 140, 80, 50 }
local RAW_PORKCHOP = { 236, 140, 140 }
local COOKED_PORKCHOP = { 206, 156, 104 }
local RAW_CHICKEN = { 238, 196, 172 }
local COOKED_CHICKEN = { 196, 132, 72 }
local FEATHER = { 244, 244, 240 }
local ROTTEN = { 120, 112, 52 }
local STRING = { 236, 236, 236 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade = define.shade
	local slab, drumstick, BONE = models.slab, models.drumstick, models.BONE
	return {
		{
			name = "Leather",
			color = LEATHER,
			material = "Fabric",
			model = {
				{ size = { 11, 11, 1.5 }, offset = { 0, 0, 0 } },
				{ size = { 3, 3, 1.5 }, offset = { -5, 5, 0 }, rotation = 30 },
				{ size = { 3, 3, 1.5 }, offset = { 5, -5, 0 }, rotation = 20 },
				{ size = { 2.5, 2.5, 1.5 }, offset = { 5, 5, 0 }, rotation = 45, color = shade(LEATHER, 0.85) },
				{ size = { 2.5, 2.5, 1.5 }, offset = { -5, -5, 0 }, rotation = 45, color = shade(LEATHER, 0.85) },
				{ size = { 6, 1, 0.4 }, offset = { -0.5, 1.5, 0.8 }, rotation = 15, color = shade(LEATHER, 1.2) },
				{ size = { 4, 1, 0.4 }, offset = { 1, -2.5, 0.8 }, rotation = -10, color = shade(LEATHER, 0.75) },
			},
			icon = "",
			lore = "Cow hide for armor, an Aglet and the Tuxedo.",
		},
		{
			name = "RawBeef",
			color = RAW_BEEF,
			model = slab(RAW_BEEF, FAT, false),
			icon = "",
			lore = "Better cooked.",
			food = { heal = 2, nutrition = 3, saturation = 0.3 },
		},
		{
			name = "CookedBeef",
			displayName = "Steak",
			color = STEAK,
			model = slab(STEAK, { 176, 136, 92 }, false),
			icon = "",
			lore = "A hearty meal.",
			knowledge = { smelt = 0.35 },
			food = { heal = 4, nutrition = 8, saturation = 0.8 },
		},
		{
			name = "RawMutton",
			color = RAW_MUTTON,
			model = slab(RAW_MUTTON, FAT, true),
			icon = "",
			lore = "Better cooked.",
			food = { heal = 1, nutrition = 2, saturation = 0.3 },
		},
		{
			name = "CookedMutton",
			color = COOKED_MUTTON,
			model = slab(COOKED_MUTTON, { 186, 140, 96 }, true),
			icon = "",
			lore = "A filling meal.",
			knowledge = { smelt = 0.35 },
			food = { heal = 3, nutrition = 6, saturation = 0.8 },
		},
		{
			name = "RawPorkchop",
			color = RAW_PORKCHOP,
			model = slab(RAW_PORKCHOP, FAT, false),
			icon = "",
			lore = "Better cooked.",
			food = { heal = 2, nutrition = 3, saturation = 0.3 },
		},
		{
			name = "CookedPorkchop",
			color = COOKED_PORKCHOP,
			model = slab(COOKED_PORKCHOP, { 232, 200, 150 }, false),
			icon = "",
			lore = "A hearty meal.",
			knowledge = { smelt = 0.35 },
			food = { heal = 4, nutrition = 8, saturation = 0.8 },
		},
		{
			name = "RawChicken",
			color = RAW_CHICKEN,
			model = drumstick(RAW_CHICKEN),
			icon = "",
			lore = "Eating it raw is a gamble. Cook it first.",
			-- (Minecraft's 30% chance of Hunger for 30 s.)
			food = {
				heal = 1,
				nutrition = 2,
				saturation = 0.3,
				effect = { kind = "hunger", chance = 0.3, ticks = 600 },
			},
		},
		{
			name = "CookedChicken",
			color = COOKED_CHICKEN,
			model = drumstick(COOKED_CHICKEN),
			icon = "",
			lore = "A filling meal.",
			knowledge = { smelt = 0.35 },
			food = { heal = 3, nutrition = 6, saturation = 0.6 },
		},
		{
			name = "Feather",
			color = FEATHER,
			material = "Fabric",
			model = {
				{ size = { 0.8, 16, 0.8 }, offset = { 0, 0, 0 }, color = { 206, 200, 186 } },
				{ size = { 3.5, 11, 1 }, offset = { -1.6, 2, 0 } },
				{ size = { 2.5, 10, 1 }, offset = { 1.4, 2.5, 0 }, color = shade(FEATHER, 0.88) },
			},
			tilt = -45,
			icon = "",
			lore = "From chickens. Three go into the Anklet of the Wind.",
		},
		{
			name = "RottenFlesh",
			color = ROTTEN,
			model = {
				{ size = { 10, 9, 3 }, offset = { 0, 0, 0 } },
				{ size = { 4, 4, 3 }, offset = { -5, -3, 0 }, rotation = 25, color = shade(ROTTEN, 0.85) },
				{ size = { 3, 3, 3 }, offset = { 5, 4, 0 }, rotation = 40 },
				{ size = { 3, 1.5, 0.4 }, offset = { -1, 1.5, 1.6 }, color = { 156, 74, 60 } },
				{ size = { 2, 2, 0.4 }, offset = { 2, -2, 1.6 }, color = { 82, 96, 40 } },
			},
			icon = "",
			lore = "Zombie meat. Eat it only if you must.",
			-- (Minecraft's 80% chance of Hunger for 30 s.)
			food = {
				heal = 2,
				nutrition = 4,
				saturation = 0.1,
				effect = { kind = "hunger", chance = 0.8, ticks = 600 },
			},
		},
		{
			name = "Bone",
			color = BONE,
			model = {
				{ size = { 2, 13, 2 }, offset = { 0, 0, 0 } },
				{ size = { 2.2, 2.2, 2 }, offset = { -1.2, 7, 0 } },
				{ size = { 2.2, 2.2, 2 }, offset = { 1.2, 7, 0 } },
				{ size = { 2.2, 2.2, 2 }, offset = { -1.2, -7, 0 } },
				{ size = { 2.2, 2.2, 2 }, offset = { 1.2, -7, 0 } },
				{ size = { 0.6, 11, 2.1 }, offset = { 0.6, 0, 0 }, color = shade(BONE, 0.85) },
			},
			tilt = -45,
			icon = "",
			lore = "Old bones. Zombies drop them now and then; ruins hide more.",
		},
		{
			name = "String",
			color = STRING,
			material = "Fabric",
			model = {
				{ size = { 0.8, 7, 0.8 }, offset = { -3, 2, 0 }, rotation = 20 },
				{ size = { 7, 0.8, 0.8 }, offset = { 0, 5, 0 }, rotation = -10 },
				{ size = { 0.8, 8, 0.8 }, offset = { 3, 0.5, 0 }, rotation = -15 },
				{ size = { 7, 0.8, 0.8 }, offset = { -0.5, -3.5, 0 }, rotation = 12 },
				{ size = { 0.8, 5, 0.8 }, offset = { -4, -5.5, 0 }, rotation = 30 },
			},
			icon = "",
			lore = "From cobwebs. Makes wool, rope and the Tuxedo.",
		},
	}
end
