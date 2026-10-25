--!strict
--[[
	The Minecraft pack's plants: the cactus, and Minecraft 1.20.1's ground foliage (BushBlock and
	its family, Content/Define's plants say how they are drawn and kept up): short grass ("Grass"
	is the grass block here; 1.20.3's name), ferns and their two block tall forms, the dead bush,
	the twelve flowers, the four tall flowers, both mushrooms and the five saplings.

	  * Minecraft's cactus sounds like wool, and is a pixel short of its cell on every side but the
	    bottom: nothing hangs on it.
	  * Short grass, ferns, their tall forms and the dead bush are replaceable, as in Minecraft
	    1.20; flowers and mushrooms are not. Grass, ferns and their tall forms are tinted by their
	    soil's foliage colour (`tinted`): their greens are the Grass block's and a shade darker and
	    lighter, which is how they look on Grass.
	  * Tall grass gives 2 short grass with Shears and large ferns 2 ferns; short grass, ferns and
	    dead bushes give themselves, and nothing (a dead bush a stick) without. Flowers and
	    mushrooms always drop themselves.
	  * Flowers: a stem with a leaf or two and a head in Minecraft's colours, up to 10 pixels tall
	    (Minecraft's 5..11 outline). Heads are two crossed boxes or one turned 45 degrees, so they
	    look round from every side.
	  * Tall flowers: two blocks like tall grass. The sunflower's yellow disc with its brown middle
	    faces east and a little up, as in Minecraft; the lilac and the peony are leafy bushes with
	    pale purple and pink blossoms on top, the rose bush a dark green bush dotted with red roses.
	    Their items show the lower half with the top's blossoms (Minecraft's item uses the top
	    half's texture), fitted in one cell; the sunflower's head faces the viewer there.
	  * Mushrooms: a short pale stem under a cap, the brown one flat and wide (two crossed slabs, a
	    pixel-art circle), the red one domed with a white spot. Minecraft's brown mushroom gives off
	    a little light (1); this one gives none.
	  * Saplings, one per wood (Minecraft's SaplingBlock): dropped by their leaves now and then
	    (Items.leafDrop); under the open sky a random tick grows one into its tree (server
	    Behaviours/Sapling, World/RandomTicker; about 16 minutes on average) when the tree has room.
	    Drawn as their texture pack sprite ("sapling": a black and white picture, tinted with each
	    sapling's colour), else as a stem with leaf lumps.
	  * What burns (Minecraft's FireBlock.bootStrap): every grass, fern, dead bush and flower, both
	    halves of the tall ones, at 60 / 100; no sapling and no mushroom.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local shapes = require(script.Parent.Parent._shapes)

type BlockSpec = Schema.BlockSpec
type Bounds = Schema.Bounds

-- (Minecraft's outline of grass, ferns and dead bushes.)
local GRASS_BOUNDS: Bounds = { min = { 2, 0, 2 }, max = { 14, 13, 14 } }
local GRASS_FIRE = { ignite = 60, burn = 100 }

-- Greens of grass and ferns.
local GRASS = { 92, 158, 62 }
local GRASS_DARK = { 72, 134, 48 }
local GRASS_LIGHT = { 118, 178, 76 }
local FERN = { 74, 140, 54 }
local FERN_DARK = { 58, 118, 44 }
local FERN_LIGHT = { 96, 160, 64 }
local TWIG = { 124, 88, 44 }
local TWIG_DARK = { 100, 70, 36 }
local TWIG_LIGHT = { 146, 108, 60 }
local WHITE = { 236, 240, 238 }

return function(define: Define.Context): { BlockSpec }
	local blade, leaf, lump, stem, along = define.blade, define.leaf, define.plantBox, define.stem, define.along
	local plant, flower, tulip, tallFlower = define.plant, define.flower, define.tulip, define.tallFlower
	local GROUND, STEM, LEAF, LEAF_LIGHT = define.GROUND, define.STEM, define.LEAF, define.LEAF_LIGHT
	local behind = shapes.behind

	local list: { BlockSpec } = {
		{
			name = "Cactus",
			color = { 64, 122, 52 },
			material = "Grass",
			hardness = 0.4,
			sound = "wool",
			sturdy = false,
		},
	}

	--[[ Grass and ferns ]]

	-- Short grass: three blades crossing at the root and splaying out, 9 to 12 pixels tall.
	table.insert(
		list,
		plant({
			name = "ShortGrass",
			displayName = "Short Grass",
			color = GRASS,
			replaceable = true,
			tinted = true,
			plant = { soil = "dirt" },
			shape = {
				blade(behind(15, 1), { 2.4, 12.5, 0.4 }, 28, 15, GRASS),
				blade(behind(140, 1), { 2, 13, 0.4 }, 20, 140, GRASS_LIGHT),
				blade(behind(255, 1), { 2.2, 10.5, 0.4 }, 34, 255, GRASS_DARK),
			},
			bounds = GRASS_BOUNDS,
			shearDrops = true,
			drops = false,
			flammable = GRASS_FIRE,
		})
	)

	-- A fern: an upright frond and two broad ones arching out low, their faces up.
	table.insert(
		list,
		plant({
			name = "Fern",
			color = FERN,
			replaceable = true,
			tinted = true,
			plant = { soil = "dirt" },
			shape = {
				blade(behind(100, 0.8), { 3, 12, 0.4 }, 12, 100, FERN),
				leaf({ 0, GROUND, 0 }, { 3, 8.5, 0.4 }, 40, 330, FERN_LIGHT),
				leaf({ 0, GROUND, 0 }, { 2.8, 7.8, 0.4 }, 46, 210, FERN_DARK),
			},
			bounds = GRASS_BOUNDS,
			shearDrops = true,
			drops = false,
			flammable = GRASS_FIRE,
		})
	)

	local tallGrass, tallGrassTop = shapes.tallBlades({
		{
			facing = 30,
			lean = 10,
			width = 2.4,
			colour = GRASS,
			length = 13,
			topLean = 11,
			topWidth = 2,
			topColour = GRASS_LIGHT,
		},
		{
			facing = 150,
			lean = 8,
			width = 2.2,
			colour = GRASS_DARK,
			length = 12,
			topLean = 15,
			topWidth = 1.8,
			topColour = GRASS,
		},
		{
			facing = 270,
			lean = 9,
			width = 2.4,
			colour = GRASS_LIGHT,
			length = 14,
			topLean = 11,
			topWidth = 2,
			topColour = GRASS_DARK,
		},
	})
	local largeFern, largeFernTop = shapes.tallBlades({
		{
			facing = 10,
			lean = 8,
			width = 3,
			colour = FERN,
			length = 12.5,
			topLean = 11,
			topWidth = 2.6,
			topColour = FERN_LIGHT,
		},
		{
			facing = 130,
			lean = 8,
			width = 2.8,
			colour = FERN_DARK,
			length = 5.8,
			topLean = 36,
			topWidth = 2.6,
			topColour = FERN,
			flat = true,
		},
		{
			facing = 250,
			lean = 8,
			width = 3,
			colour = FERN_LIGHT,
			length = 5.8,
			topLean = 36,
			topWidth = 2.6,
			topColour = FERN_DARK,
			flat = true,
		},
	})

	-- Their items: the lower half with shorter blades fanning out of it, like the upper half's.
	define.append(
		list,
		define.tallPlant({
			name = "TallGrass",
			displayName = "Tall Grass",
			color = GRASS,
			replaceable = true,
			tinted = true,
			shape = tallGrass,
			icon = define.tallIcon(tallGrass, {
				blade({ 0, -3, 0 }, { 2, 10, 0.4 }, 34, 90, GRASS_LIGHT),
				blade({ 0, -4, 0 }, { 2, 10, 0.4 }, 36, 200, GRASS),
				blade({ 0, -2, 0 }, { 1.8, 9, 0.4 }, 30, 320, GRASS_DARK),
			}),
			shearDrops = "ShortGrass",
			shearCount = 2,
			drops = false,
			flammable = GRASS_FIRE,
		}, {
			name = "TallGrassTop",
			displayName = "Tall Grass",
			color = GRASS,
			replaceable = true,
			tinted = true,
			shape = tallGrassTop,
			flammable = GRASS_FIRE,
		})
	)
	define.append(
		list,
		define.tallPlant({
			name = "LargeFern",
			displayName = "Large Fern",
			color = FERN,
			replaceable = true,
			tinted = true,
			shape = largeFern,
			icon = define.tallIcon(largeFern, {
				leaf({ 0, -1, 0 }, { 3, 8, 0.4 }, 48, 90, FERN_LIGHT),
				leaf({ 0, -2, 0 }, { 3, 8, 0.4 }, 50, 200, FERN),
				blade({ 0, -3, 0 }, { 2.6, 10, 0.4 }, 32, 320, FERN_DARK),
			}),
			shearDrops = "Fern",
			shearCount = 2,
			drops = false,
			flammable = GRASS_FIRE,
		}, {
			name = "LargeFernTop",
			displayName = "Large Fern",
			color = FERN,
			replaceable = true,
			tinted = true,
			shape = largeFernTop,
			flammable = GRASS_FIRE,
		})
	)

	-- The dead bush: brown twigs, a main one and three splaying out (one a branch off it).
	table.insert(
		list,
		plant({
			name = "DeadBush",
			displayName = "Dead Bush",
			color = TWIG,
			replaceable = true,
			plant = { soil = "deadbush" },
			shape = {
				blade({ 0, GROUND, 0 }, { 0.8, 11.5, 0.8 }, 8, 100, TWIG),
				blade({ 0.2, GROUND, 0.1 }, { 0.7, 8.5, 0.7 }, 40, 15, TWIG_DARK),
				blade({ -0.1, GROUND, 0.1 }, { 0.7, 8, 0.7 }, 42, 150, TWIG_LIGHT),
				blade(along({ 0, GROUND, 0 }, 8, 100, 4.5), { 0.6, 6.5, 0.6 }, 40, 255, TWIG),
			},
			bounds = GRASS_BOUNDS,
			shearDrops = true,
			drops = "Stick" :: string,
			flammable = GRASS_FIRE,
		})
	)

	--[[ Flowers ]]

	local DANDELION = { 255, 216, 36 }
	table.insert(
		list,
		flower("Dandelion", DANDELION, {
			stem(6),
			leaf({ 0, GROUND, 0 }, { 1.4, 3.2, 0.4 }, 58, 30, LEAF),
			lump({ 3.2, 2, 2.2 }, { 0, -1.2, 0 }, DANDELION, { 0, 20, 0 }),
			lump({ 2.2, 2.4, 3.2 }, { 0, -1.2, 0 }, { 246, 196, 30 }, { 0, 20, 0 }),
		})
	)

	local POPPY = { 214, 34, 30 }
	table.insert(
		list,
		flower("Poppy", POPPY, {
			stem(7, 4, 0),
			leaf({ 0, -6.5, 0 }, { 1.4, 3.4, 0.4 }, 50, 220, LEAF),
			lump({ 3.6, 2.6, 3.6 }, { 0.3, 0.1, 0 }, POPPY, { 0, 30, 0 }),
			-- The dark middle, seen from above.
			lump({ 1.3, 0.3, 1.3 }, { 0.3, 1.5, 0 }, { 44, 36, 20 }, { 0, 30, 0 }),
		})
	)

	-- The blue orchid: a star of bright blue petals, two crossed and tilted.
	local ORCHID = { 40, 168, 228 }
	local orchidTop = along({ 0, GROUND, 0 }, 6, 300, 6.5)
	table.insert(
		list,
		flower("BlueOrchid", ORCHID, {
			stem(6.5, 6, 300),
			leaf({ 0, GROUND, 0 }, { 1.2, 4, 0.4 }, 30, 120, LEAF),
			lump({ 3.8, 1, 1.4 }, { orchidTop[1], orchidTop[2] + 0.3, orchidTop[3] }, ORCHID, { 0, 20, 18 }),
			lump(
				{ 1.4, 1.2, 3.8 },
				{ orchidTop[1], orchidTop[2] + 0.6, orchidTop[3] },
				{ 96, 200, 244 },
				{ -15, 20, 0 }
			),
		}, "Blue Orchid")
	)

	local ALLIUM = { 166, 92, 212 }
	table.insert(
		list,
		flower("Allium", ALLIUM, {
			stem(7.5),
			leaf({ 0, GROUND, 0 }, { 1, 4.5, 0.35 }, 28, 160, LEAF),
			lump({ 3.6, 2.4, 3.6 }, { 0, 0.25, 0 }, ALLIUM),
			lump({ 2.6, 3.4, 2.6 }, { 0, 0.25, 0 }, { 192, 132, 230 }, { 0, 45, 0 }),
		})
	)

	-- The azure bluet: a pale stem with a white flower and its yellow middle, and a bud lower down.
	local BLUET_STEM = { 116, 146, 98 }
	local bluetTop = along({ 0, GROUND, 0 }, 6, 30, 5.6)
	table.insert(
		list,
		flower("AzureBluet", WHITE, {
			blade({ 0, GROUND, 0 }, { 0.6, 5.6, 0.6 }, 6, 30, BLUET_STEM),
			lump({ 2.6, 0.8, 2.6 }, { bluetTop[1], bluetTop[2] + 0.2, bluetTop[3] }, WHITE, { 0, 45, 0 }),
			lump({ 1, 0.4, 1 }, { bluetTop[1], bluetTop[2] + 0.7, bluetTop[3] }, { 232, 204, 70 }, { 0, 45, 0 }),
			lump({ 1.8, 0.7, 1.8 }, { -1, -4.2, 0.6 }, { 226, 232, 236 }, { 0, 20, 0 }),
		}, "Azure Bluet")
	)

	-- Tulips: a cup on a stem between two long leaves (Content/Define's `tulip`).
	table.insert(list, tulip("RedTulip", { 212, 42, 34 }))
	table.insert(list, tulip("OrangeTulip", { 240, 128, 36 }))
	table.insert(list, tulip("WhiteTulip", { 234, 238, 234 }))
	table.insert(list, tulip("PinkTulip", { 238, 162, 198 }))

	table.insert(
		list,
		flower("OxeyeDaisy", WHITE, {
			stem(6.5),
			leaf({ 0, GROUND, 0 }, { 1.4, 3.2, 0.4 }, 50, 300, LEAF),
			lump({ 4, 0.9, 4 }, { 0, -0.8, 0 }, { 242, 242, 238 }, { 12, 45, 0 }),
			lump({ 1.6, 0.5, 1.6 }, { 0, -0.25, 0.1 }, { 236, 196, 40 }, { 12, 45, 0 }),
		}, "Oxeye Daisy")
	)

	local CORNFLOWER = { 70, 104, 228 }
	table.insert(
		list,
		flower("Cornflower", CORNFLOWER, {
			stem(6.5),
			leaf({ 0, GROUND, 0 }, { 1, 4.2, 0.35 }, 30, 70, LEAF),
			lump({ 3, 1.8, 3 }, { 0, -1, 0 }, CORNFLOWER, { 0, 45, 0 }),
			lump({ 1.8, 2.6, 1.8 }, { 0, -0.2, 0 }, { 50, 78, 200 }),
		})
	)

	-- Lily of the valley: two broad upright leaves and an arching stem with white bells under its tip.
	local LILY_LEAF = { 62, 130, 48 }
	local lilyTop = along({ 0, GROUND, 0 }, 15, 100, 7)
	table.insert(
		list,
		flower("LilyOfTheValley", WHITE, {
			blade({ -0.4, GROUND, 0.2 }, { 2.2, 7.5, 0.4 }, 8, 200, LILY_LEAF),
			blade({ 0.4, GROUND, -0.2 }, { 2, 6.5, 0.4 }, 12, 20, LEAF_LIGHT),
			blade({ 0, GROUND, 0 }, { 0.5, 7, 0.5 }, 15, 100, STEM),
			-- (A row of bells along the arch, hanging under it.)
			lump(
				{ 1.2, 1.4, 2.4 },
				{ lilyTop[1] * 0.8, lilyTop[2] - 1.1, lilyTop[3] * 0.75 },
				{ 244, 246, 240 },
				{ 0, 10, 0 }
			),
		}, "Lily of the Valley")
	)

	--[[ Tall flowers ]]

	-- (The stem leans a little east, under the head.)
	local SUN_PETALS = { 252, 200, 32 }
	local sunStemTop = along({ 0, GROUND, 0 }, 12, 0, 8.5)
	local sunflowerTop = { blade({ 0, GROUND, 0 }, { 1.2, 8.5, 1.2 }, 12, 0, STEM) }
	for _, box in shapes.sunflowerHead({ sunStemTop[1] + 0.5, sunStemTop[2] + 1, 0 }, true) do
		table.insert(sunflowerTop, box)
	end
	define.append(
		list,
		tallFlower("Sunflower", SUN_PETALS, {
			blade({ 0, GROUND, 0 }, { 1.2, 16, 1.2 }, 0, 0, STEM),
			leaf({ 0, -3, 0 }, { 2.4, 5.5, 0.4 }, 55, 160, LEAF),
			leaf({ 0, 2, 0 }, { 2.2, 5, 0.4 }, 50, 340, LEAF_LIGHT),
		}, sunflowerTop, shapes.sunflowerHead({ 0, 3.4, -0.9 }, false))
	)

	local BUSH_LEAVES = { 70, 124, 46 }
	local BUSH_LEAVES_LIGHT = { 90, 146, 58 }
	local ROSE_LEAVES = { 44, 100, 36 }
	local ROSE_LEAVES_LIGHT = { 58, 120, 44 }

	local LILAC = { 196, 148, 212 }
	local LILAC_LIGHT = { 220, 180, 232 }
	local lilacLower = shapes.bushLower(BUSH_LEAVES, BUSH_LEAVES_LIGHT)
	table.insert(lilacLower, leaf({ 0, -6, 0 }, { 2.6, 5, 0.5 }, 50, 120, BUSH_LEAVES_LIGHT))
	define.append(
		list,
		tallFlower("Lilac", LILAC, lilacLower, {
			shapes.bushUpper(BUSH_LEAVES),
			lump({ 4.6, 6.5, 4.6 }, { 0.6, -0.4, -0.4 }, LILAC, { 0, 15, -8 }),
			lump({ 3.4, 5, 3.4 }, { -0.5, 3.4, 0.6 }, LILAC_LIGHT, { 10, 60, 0 }),
			leaf({ 0.5, -4, -0.5 }, { 2.4, 4.5, 0.5 }, 55, 300, BUSH_LEAVES_LIGHT),
		}, {
			lump({ 5.8, 4.4, 5.8 }, { 1.2, 5.4, -0.6 }, LILAC, { 0, 40, 0 }),
			lump({ 3.6, 3, 3.6 }, { 0.8, 6.4, -0.4 }, LILAC_LIGHT, { 0, 70, 0 }),
		})
	)

	local ROSE = { 206, 28, 34 }
	local rose = shapes.rose
	local roseLower = shapes.bushLower(ROSE_LEAVES, ROSE_LEAVES_LIGHT)
	table.insert(roseLower, rose({ 2.4, -4, 2.6 }))
	table.insert(roseLower, rose({ -2.6, 4.4, -1.6 }))
	define.append(
		list,
		tallFlower("RoseBush", ROSE, roseLower, {
			shapes.bushUpper(ROSE_LEAVES),
			lump({ 4.6, 5, 4.6 }, { 0.8, 0.4, -0.5 }, ROSE_LEAVES_LIGHT, { 0, 10, -10 }),
			rose({ -3, -3, 2 }),
			rose({ 1.6, 2.6, 1.4 }),
		}, { rose({ 1, 7.4, -0.6 }) }, "Rose Bush")
	)

	local PEONY = { 236, 176, 220 }
	local PEONY_LIGHT = { 248, 206, 236 }
	local peonyLower = shapes.bushLower(BUSH_LEAVES_LIGHT, BUSH_LEAVES)
	table.insert(peonyLower, leaf({ 0, -6, 0 }, { 2.6, 5, 0.5 }, 50, 300, BUSH_LEAVES))
	define.append(
		list,
		tallFlower("Peony", PEONY, peonyLower, {
			shapes.bushUpper(BUSH_LEAVES_LIGHT),
			lump({ 5.4, 4, 5.4 }, { 0.6, -0.8, -0.4 }, PEONY, { 10, 15, -6 }),
			lump({ 4, 3.4, 4 }, { -0.6, 1.8, 0.5 }, PEONY_LIGHT, { -8, 55, 0 }),
			leaf({ 0.5, -4, -0.5 }, { 2.4, 4.5, 0.5 }, 55, 120, BUSH_LEAVES),
		}, {
			lump({ 5.8, 3.6, 5.8 }, { 1.2, 5.8, -0.6 }, PEONY, { 0, 15, 0 }),
			lump({ 3.6, 2.4, 3.6 }, { 0.6, 6.6, -0.2 }, PEONY_LIGHT, { 0, 55, 0 }),
		})
	)

	--[[ Mushrooms ]]

	local BROWN_CAP = { 152, 112, 84 }
	table.insert(
		list,
		define.mushroom("BrownMushroom", BROWN_CAP, {
			lump({ 1.6, 3.6, 1.6 }, { 0, -6.2, 0 }, { 212, 196, 164 }),
			lump({ 4.8, 1.4, 3.2 }, { 0, -3.8, 0 }, BROWN_CAP),
			lump({ 3.2, 1.4, 4.8 }, { 0, -3.8, 0 }, BROWN_CAP),
		}, "Brown Mushroom")
	)

	local RED_CAP = { 200, 36, 32 }
	table.insert(
		list,
		define.mushroom("RedMushroom", RED_CAP, {
			lump({ 1.6, 3.4, 1.6 }, { 0, -6.3, 0 }, { 228, 220, 206 }),
			lump({ 4.2, 1.6, 4.2 }, { 0, -4.4, 0 }, RED_CAP, { 0, 45, 0 }),
			lump({ 2.8, 1.2, 2.8 }, { 0, -3.1, 0 }, RED_CAP),
			lump({ 0.9, 0.3, 0.9 }, { 0.5, -2.4, -0.4 }, { 246, 240, 232 }),
		}, "Red Mushroom")
	)

	--[[ Saplings ]]

	table.insert(list, define.sapling("OakSapling", { 72, 124, 44 }, "Oak Sapling"))
	table.insert(list, define.sapling("BirchSapling", { 116, 152, 72 }, "Birch Sapling"))
	table.insert(list, define.sapling("SpruceSapling", { 50, 92, 58 }, "Spruce Sapling"))
	table.insert(list, define.sapling("AcaciaSapling", { 112, 140, 44 }, "Acacia Sapling"))
	table.insert(list, define.sapling("JungleSapling", { 46, 124, 36 }, "Jungle Sapling"))
	return list
end
