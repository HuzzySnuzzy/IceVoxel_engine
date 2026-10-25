--!strict
--[[
	Terraria's things (Config.Characters, Accessories, Mana): its early accessories, mana (Fallen
	Stars, Mana Crystals, mana potions), magic weapons and vanity clothes. Box models in their
	colours until their icons are made (TexturePack's LEGACY_ICONS still names them, blank).

	  * Accessories (`accessory`, Items/Accessories): Hermes Boots (winged boots), Cloud in a Bottle
	    (a bottle with a white puff), Shiny Red Balloon, Lucky Horseshoe (gold), Aglet (a lace's
	    metal tip), Anklet of the Wind (a green band with feathers), Band of Regeneration (a red
	    ring with a heart gem) and Band of Starpower (a blue ring with a star), Obsidian Skull,
	    Flipper (green fins), Cobalt Shield (a blue round shield) and Feral Claws (a tan glove with
	    claws). How each is found: the pack's recipes, the Minecraft pack's mineshaft loot (its
	    fourth pool), the Apocalypse pack's loot (Feral Claws: the ruins' and bunkers').
	  * Mana (Shared/Mana): the Fallen Star, which falls at night and glows (server
	    Players/FallenStars); five make a Mana Crystal, which raises max mana by 20 for good (nine
	    at most: Config.Mana); and Terraria's Lesser Mana Potion (50 mana) and Mana Potion (100),
	    drunk like the potions (ToughAsNails/Drinks), each giving Mana Sickness. They stack to 16,
	    as the filled bottles.
	  * Magic weapons (`magic`; server Players/Magic, Shared/Magic): Terraria's Wand of Sparking (a
	    stick with a glowing ember, found in mineshafts), an Emerald Staff (Terraria's gem staves:
	    an emerald on a long staff, crafted) and Water Bolt (a blue spell book whose bolt bounces,
	    found in mineshafts). Modelled upright and tilted like the tools.
	  * Vanity clothes (`vanity`: looks only, Terraria's Clothier's suit): a Top Hat, a Tuxedo
	    Shirt and Tuxedo Pants, black with a white shirt front and a red band and bow tie. Armor
	    fits the vanity armor slots too (its look over the worn armor's).
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)
local models = require(script.Parent._models)

local WHITE = { 250, 250, 250 }
local DARK = { 28, 26, 32 }
local GOLD = { 250, 213, 58 }
local IRON = { 222, 222, 224 }
local EMERALD = { 40, 210, 90 }
local FEATHER = { 244, 244, 240 }
local HERMES = { 150, 96, 62 }
local CLOUD = { 236, 242, 250 }
local BALLOON = { 214, 36, 40 }
local LACE = { 70, 60, 52 }
local ANKLET = { 70, 168, 96 }
local REGEN = { 206, 52, 62 }
local STARPOWER = { 64, 96, 222 }
local STAR = { 255, 222, 74 }
local OBSIDIAN = { 64, 44, 92 }
local FLIPPER = { 64, 156, 92 }
local COBALT = { 40, 92, 206 }
local CLAWS = { 196, 156, 104 }
local MANA_BLUE = { 74, 112, 255 }
local LESSER_MANA = { 96, 140, 255 }
local MANA = { 44, 72, 236 }
local EMBER = { 255, 128, 40 }
local BOOK = { 44, 104, 206 }
local SUIT = { 34, 34, 40 }
local SUIT_RED = { 176, 30, 40 }

return function(define: Define.Context): { Schema.ItemSpec }
	local shade, ring, star = define.shade, models.ring, models.star

	local cloudBottle = define.bottle(nil)
	table.insert(cloudBottle, { size = { 3.5, 3.5, 3.5 }, offset = { -1.2, -4.2, 0.6 }, shape = "Ball", color = WHITE })
	table.insert(cloudBottle, { size = { 3, 3, 3 }, offset = { 1.5, -3.6, 0.6 }, shape = "Ball", color = WHITE })
	table.insert(cloudBottle, { size = { 2.5, 2.5, 2.5 }, offset = { 0.2, -2.4, 0.6 }, shape = "Ball", color = WHITE })
	local crystal = star(MANA_BLUE, 5, "Glass")
	table.insert(
		crystal,
		{ size = { 2.4, 2.4, 2.8 }, offset = { -1, 1, 0 }, rotation = 45, color = { 190, 210, 255 }, material = "Neon" }
	)
	local shirt = table.clone(define.CHESTPLATE)
	table.insert(shirt, { size = { 3, 9, 0.4 }, offset = { 0, -1, 2.1 }, color = WHITE })
	table.insert(shirt, { size = { 3, 1.4, 0.6 }, offset = { 0, 3, 2.3 }, color = SUIT_RED })

	return {
		--[[ Accessories ]]
		{
			name = "HermesBoots",
			maxStack = 1,
			accessory = { runBoost = 0.4, worn = "Feet" },
			color = HERMES,
			material = "Fabric",
			model = {
				{ size = { 4, 4, 4 }, offset = { -3, 0, -1 } },
				{ size = { 4, 4, 4 }, offset = { 3, 0, -1 } },
				{ size = { 4, 2, 3 }, offset = { -3, -1, 2.5 } },
				{ size = { 4, 2, 3 }, offset = { 3, -1, 2.5 } },
				{ size = { 4.2, 0.8, 7.2 }, offset = { -3, -2.4, 0.6 }, color = shade(HERMES, 0.55) },
				{ size = { 4.2, 0.8, 7.2 }, offset = { 3, -2.4, 0.6 }, color = shade(HERMES, 0.55) },
				{ size = { 3.4, 1.3, 0.6 }, offset = { -6.2, 2.6, -1 }, rotation = 30, color = WHITE },
				{ size = { 3.4, 1.3, 0.6 }, offset = { 6.2, 2.6, -1 }, rotation = -30, color = WHITE },
				{ size = { 2.6, 1, 0.6 }, offset = { -6.4, 1.2, -1 }, rotation = 12, color = WHITE },
				{ size = { 2.6, 1, 0.6 }, offset = { 6.4, 1.2, -1 }, rotation = -12, color = WHITE },
			},
		},
		{
			name = "CloudInABottle",
			displayName = "Cloud in a Bottle",
			maxStack = 1,
			accessory = { airJumps = 1, worn = "Waist" },
			color = CLOUD,
			material = "Glass",
			model = cloudBottle,
		},
		{
			name = "ShinyRedBalloon",
			maxStack = 1,
			accessory = { jump = 0.1, worn = "Back" },
			color = BALLOON,
			material = "SmoothPlastic",
			model = {
				{ size = { 9, 9, 9 }, offset = { 0, 2.5, 0 }, shape = "Ball" },
				{ size = { 2.4, 2.4, 2.4 }, offset = { -2, 4.6, 3 }, shape = "Ball", color = { 255, 168, 168 } },
				{ size = { 1.4, 1.2, 1.4 }, offset = { 0, -2.3, 0 }, color = shade(BALLOON, 0.75) },
				{ size = { 0.4, 5, 0.4 }, offset = { 0.3, -5.4, 0 }, rotation = -8, color = WHITE },
			},
		},
		{
			name = "LuckyHorseshoe",
			maxStack = 1,
			accessory = { noFallDamage = true, worn = "Waist" },
			color = GOLD,
			material = "Metal",
			model = {
				{ size = { 2.2, 9, 2 }, offset = { -4, -0.5, 0 } },
				{ size = { 2.2, 9, 2 }, offset = { 4, -0.5, 0 } },
				{ size = { 6, 2.2, 2 }, offset = { 0, 4.9, 0 } },
				{ size = { 1.8, 1.8, 2 }, offset = { -3.3, 4.2, 0 }, rotation = 45 },
				{ size = { 1.8, 1.8, 2 }, offset = { 3.3, 4.2, 0 }, rotation = 45 },
				{ size = { 0.8, 0.8, 0.4 }, offset = { -4, -2.5, 1.1 }, color = shade(GOLD, 0.5) },
				{ size = { 0.8, 0.8, 0.4 }, offset = { 4, -2.5, 1.1 }, color = shade(GOLD, 0.5) },
				{ size = { 0.8, 0.8, 0.4 }, offset = { -4, 1, 1.1 }, color = shade(GOLD, 0.5) },
				{ size = { 0.8, 0.8, 0.4 }, offset = { 4, 1, 1.1 }, color = shade(GOLD, 0.5) },
			},
		},
		{
			name = "Aglet",
			maxStack = 1,
			accessory = { speed = 0.05, worn = "Feet" },
			color = IRON,
			material = "Metal",
			model = {
				{ size = { 2, 6, 2 }, offset = { 2, -2.5, 0 }, rotation = -35 },
				{ size = { 2.4, 1, 2.4 }, offset = { 0.4, 0, 0 }, rotation = -35, color = shade(IRON, 0.7) },
				{ size = { 1, 9, 1 }, offset = { -2, 4, 0 }, rotation = -35, color = LACE, material = "Fabric" },
			},
		},
		{
			name = "AnkletOfTheWind",
			displayName = "Anklet of the Wind",
			maxStack = 1,
			accessory = { speed = 0.1, worn = "Feet" },
			color = ANKLET,
			material = "Fabric",
			model = {
				{ size = { 10, 10, 2 }, offset = { 0, -2, 0 }, shape = "Cylinder" },
				{ size = { 7, 7, 2.2 }, offset = { 0, -2, 0 }, shape = "Cylinder", color = DARK },
				{ size = { 2, 7, 0.6 }, offset = { -3, 4.5, 0.6 }, rotation = 20, color = FEATHER },
				{ size = { 2, 7, 0.6 }, offset = { 3, 4.5, 0.6 }, rotation = -20, color = FEATHER },
				{ size = { 1.6, 6, 0.6 }, offset = { 0, 5, 0.4 }, color = shade(FEATHER, 0.85) },
			},
		},
		{
			name = "BandOfRegeneration",
			displayName = "Band of Regeneration",
			maxStack = 1,
			accessory = { regen = 200, worn = "Hand" },
			color = REGEN,
			material = "Metal",
			model = ring(REGEN, {
				{
					size = { 3, 3, 3 },
					offset = { 0, 4.8, 0 },
					rotation = 45,
					color = { 255, 120, 140 },
					material = "Glass",
				},
			}),
		},
		{
			name = "BandOfStarpower",
			displayName = "Band of Starpower",
			maxStack = 1,
			accessory = { mana = 20, worn = "Hand" },
			color = STARPOWER,
			material = "Metal",
			model = ring(STARPOWER, {
				{ size = { 3.4, 3.4, 3 }, offset = { 0, 4.8, 0 }, rotation = 36, color = STAR, material = "Neon" },
				{ size = { 1.5, 2.6, 2.8 }, offset = { 0, 6.6, 0 }, color = STAR, material = "Neon" },
			}),
		},
		{
			name = "ObsidianSkull",
			maxStack = 1,
			accessory = { defense = 1, fireWalk = true, worn = "Face" },
			color = OBSIDIAN,
			material = "Glass",
			model = {
				{ size = { 10, 8, 8 }, offset = { 0, 1.5, 0 } },
				{ size = { 7, 3, 6.5 }, offset = { 0, -3.5, 0.5 } },
				{ size = { 2.6, 2.6, 0.4 }, offset = { -2.2, 1.6, 4.1 }, color = DARK },
				{ size = { 2.6, 2.6, 0.4 }, offset = { 2.2, 1.6, 4.1 }, color = DARK },
				{ size = { 1.2, 1.6, 0.4 }, offset = { 0, -1, 4.1 }, color = DARK },
				{ size = { 5, 0.5, 0.4 }, offset = { 0, -3.6, 3.85 }, color = DARK },
				{ size = { 3, 1.5, 0.4 }, offset = { -2.5, 4.2, 4.1 }, color = shade(OBSIDIAN, 1.5) },
			},
		},
		{
			name = "Flipper",
			maxStack = 1,
			accessory = { swim = 1, worn = "Feet" },
			color = FLIPPER,
			material = "SmoothPlastic",
			model = {
				{ size = { 4, 3, 4 }, offset = { -3, 3, 0 } },
				{ size = { 4, 3, 4 }, offset = { 3, 3, 0 } },
				{ size = { 5, 8, 1 }, offset = { -3.4, -2.5, 0 }, rotation = -8 },
				{ size = { 5, 8, 1 }, offset = { 3.4, -2.5, 0 }, rotation = 8 },
				{ size = { 0.6, 6, 1.2 }, offset = { -3.4, -2.5, 0 }, rotation = -8, color = shade(FLIPPER, 0.7) },
				{ size = { 0.6, 6, 1.2 }, offset = { 3.4, -2.5, 0 }, rotation = 8, color = shade(FLIPPER, 0.7) },
			},
		},
		{
			name = "CobaltShield",
			maxStack = 1,
			accessory = { knockback = 1, defense = 1, worn = "Hand" },
			color = COBALT,
			material = "Metal",
			model = {
				{ size = { 13, 13, 1.5 }, offset = { 0, 0, 0 }, shape = "Cylinder" },
				{ size = { 10, 10, 1.7 }, offset = { 0, 0, 0 }, shape = "Cylinder", color = shade(COBALT, 1.25) },
				{ size = { 3.5, 3.5, 2.5 }, offset = { 0, 0, 0.5 }, shape = "Cylinder", color = IRON },
			},
		},
		{
			name = "FeralClaws",
			maxStack = 1,
			accessory = { attackSpeed = 0.12, worn = "Hand" },
			color = CLAWS,
			material = "Fabric",
			model = {
				{ size = { 8, 7, 3.5 }, offset = { 0, -2, 0 } },
				{ size = { 3, 4, 3 }, offset = { -5, -1, 0 }, rotation = 30 },
				{ size = { 1.2, 4, 1.2 }, offset = { -2.6, 3.6, 0.6 }, rotation = 10, color = WHITE },
				{ size = { 1.2, 4.5, 1.2 }, offset = { 0, 3.8, 0.6 }, color = WHITE },
				{ size = { 1.2, 4, 1.2 }, offset = { 2.6, 3.6, 0.6 }, rotation = -10, color = WHITE },
				{ size = { 8.2, 1.2, 3.6 }, offset = { 0, -5, 0 }, color = shade(CLAWS, 0.65) },
			},
		},

		--[[ Mana ]]
		{
			name = "FallenStar",
			color = STAR,
			material = "Neon",
			model = star(STAR, 5, "Neon"),
		},
		{
			name = "ManaCrystal",
			color = MANA_BLUE,
			material = "Glass",
			model = crystal,
		},
		{
			name = "LesserManaPotion",
			maxStack = 16,
			color = LESSER_MANA,
			material = "Glass",
			model = define.bottle(LESSER_MANA),
		},
		{
			name = "ManaPotion",
			maxStack = 16,
			color = MANA,
			material = "Glass",
			model = define.bottle(MANA),
		},

		--[[ Magic weapons ]]
		{
			name = "WandOfSparking",
			displayName = "Wand of Sparking",
			maxStack = 1,
			magic = { mana = 2, damage = 3, useTicks = 9, projectile = "spark", fire = 0.5 },
			color = EMBER,
			material = "Wood",
			model = {
				{ size = { 1.5, 13, 1.5 }, offset = { 0, -2, 0 }, color = define.HANDLE },
				{ size = { 2.2, 1, 2.2 }, offset = { 0, 4.8, 0 }, color = GOLD, material = "Metal" },
				{ size = { 2.6, 2.6, 2.6 }, offset = { 0, 6.8, 0 }, rotation = 45, material = "Neon" },
			},
			tilt = -45,
		},
		{
			name = "EmeraldStaff",
			maxStack = 1,
			magic = { mana = 6, damage = 5, useTicks = 12, projectile = "bolt", knockback = 0.25 },
			color = EMERALD,
			material = "Wood",
			model = {
				{ size = { 1.5, 16, 1.5 }, offset = { 0, -2, 0 }, color = define.HANDLE_DARK },
				{ size = { 1, 3, 1.2 }, offset = { -1.6, 6.6, 0 }, rotation = 20, color = GOLD, material = "Metal" },
				{ size = { 1, 3, 1.2 }, offset = { 1.6, 6.6, 0 }, rotation = -20, color = GOLD, material = "Metal" },
				{ size = { 3, 3.6, 2.4 }, offset = { 0, 7.4, 0 }, material = "Glass" },
				{ size = { 1, 1.4, 0.4 }, offset = { -0.6, 8, 1.3 }, color = { 170, 255, 190 }, material = "Neon" },
			},
			tilt = -45,
		},
		{
			name = "WaterBolt",
			maxStack = 1,
			magic = { mana = 10, damage = 4, useTicks = 9, projectile = "water", knockback = 0.2 },
			color = BOOK,
			material = "Fabric",
			model = {
				{ size = { 11, 13, 0.6 }, offset = { 0, 0, 1.2 } },
				{ size = { 11, 13, 0.6 }, offset = { 0, 0, -1.2 } },
				{
					size = { 10, 12, 1.9 },
					offset = { 0.4, 0, 0 },
					color = { 236, 230, 212 },
					material = "SmoothPlastic",
				},
				{ size = { 1.2, 13, 3 }, offset = { -5.4, 0, 0 }, color = shade(BOOK, 0.65) },
				{
					size = { 3.2, 3.2, 0.4 },
					offset = { 0.5, 0.5, 1.6 },
					rotation = 45,
					color = { 140, 210, 255 },
					material = "Neon",
				},
			},
		},

		--[[ Vanity clothes ]]
		{
			name = "TopHat",
			maxStack = 1,
			vanity = "Head",
			color = SUIT,
			material = "Fabric",
			model = {
				{ size = { 13, 1.5, 9 }, offset = { 0, -5, 0 } },
				{ size = { 8, 9, 6 }, offset = { 0, 0.75, 0 } },
				{ size = { 8.2, 1.5, 6.2 }, offset = { 0, -3.2, 0 }, color = SUIT_RED },
			},
		},
		{
			name = "TuxedoShirt",
			maxStack = 1,
			vanity = "Chest",
			color = SUIT,
			material = "Fabric",
			model = shirt,
		},
		{
			name = "TuxedoPants",
			maxStack = 1,
			vanity = "Legs",
			color = SUIT,
			material = "Fabric",
			model = define.LEGGINGS,
		},
	}
end
