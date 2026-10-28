--!strict
--[[
	The Minecraft pack's light sources: the torch and wall torch, the Glow Block, the lantern and
	glow lichen. Torches and lanterns are shaped (pixels from the cell's centre; Content/Define's
	`torch`, `wallTorch` and `lantern`) and need a block to hang on; the light is a PointLight on
	the `glow` box (client Rendering/PartPool). Torches, lanterns and the Glow Block are never
	textured (boxes standing in their cell; Neon takes no MaterialVariant). The lantern is the
	Iron Age's (`age`).

	  * Wall torches face away from the wall they hang on (Minecraft's wall_torch `facing`): placed
	    by the Torch item, they drop a Torch. The mineshafts hang their cave twins
	    (CaveWallTorch*: Generation/Mineshafts puts a twin in cave air, the block in the open).
	  * The Glow Block: a full glowing cube of glow dust (Neon, blue), in place of Minecraft's
	    glowstone (the game has no Nether; its dust comes from glow lichen in caves). Minecraft's
	    glowstone drops 2-4 dust (random); here always 4, which craft back into the block. It was
	    named "Glowstone" (`formerly`: saves and structures that name it still find it).
	  * Glow lichen (Minecraft 1.20.1's GlowLichenBlock, a multiface block; here one face per
	    block): GlowLichen lies on the block below (the item), GlowLichenUp hangs under the one
	    above and GlowLichenNorth / South / West / East cover the wall on that side (`support`, kept
	    up by the Attached behaviour like torches). Light 7 in a cool yellow green, hardness 0.2,
	    mined fastest with an axe; it drops 2 Glow Dust (the game's glowing dust, which only lichen
	    gives), or itself with Shears (Minecraft's only drop; 2 x slower with them than on leaves:
	    `shearSpeed`), is replaceable, is washed away by flowing water and burns (Minecraft's 15 /
	    100). Each is a very thin plate a tenth of a pixel off its face, with a small Neon speck
	    that carries the light (`glow`; the client gives only some lichen a PointLight, chosen by
	    position): two boxes, so two Parts a lichen, as caves hold thousands of them. The outline
	    is Minecraft's: a pixel thick plate over the whole face (the pack's _shapes).
	    CaveGlowLichen and its Up / North / South / West / East forms are the cave twins
	    generation places on cave walls (`caveTwin`): exactly their twin, but cave air while caves
	    are hidden, so a whole cave's lichen costs nothing until the player is in it.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local shapes = require(script.Parent.Parent._shapes)

type BlockSpec = Schema.BlockSpec

local WOOD = { 104, 76, 42 }
local TORCH_LIGHT = { 255, 196, 128 }
local IRON = { 62, 64, 72 }
local LICHEN = { 106, 128, 118 }
local LICHEN_LIGHT = { 190, 232, 168 }

return function(define: Define.Context): { BlockSpec }
	local list: { BlockSpec } = {
		{
			name = "Torch",
			color = WOOD,
			material = "Wood",
			sound = "wood",
			solid = false,
			placeable = true,
			hardness = 0,
			light = 14,
			lightColor = TORCH_LIGHT,
			shape = define.torch({ 0, -8, 0 }),
			bounds = { min = { 6, 0, 6 }, max = { 10, 10, 10 } },
			support = "Down",
			brokenByFluid = true,
			behaviour = "Attached",
			lore = "Lights the dark. Place it on the ground or a wall.",
		},
	}

	-- The wall torches, then the mineshafts' cave twins of them.
	local wallTorches: { BlockSpec } = {}
	for _, facing in { "North", "South", "West", "East" } do
		local shape, bounds = define.wallTorch(facing)
		table.insert(wallTorches, {
			name = "WallTorch" .. facing,
			displayName = "Wall Torch",
			color = WOOD,
			material = "Wood",
			sound = "wood",
			solid = false,
			placeable = false,
			hardness = 0,
			light = 14,
			lightColor = TORCH_LIGHT,
			shape = shape,
			bounds = bounds,
			support = define.OPPOSITE[facing],
			item = "Torch",
			brokenByFluid = true,
			behaviour = "Attached",
		})
	end
	define.append(list, wallTorches)
	for _, torch in wallTorches do
		table.insert(list, define.caveTwin(torch))
	end

	define.append(list, {
		{
			name = "GlowBlock",
			displayName = "Glow Block",
			color = { 104, 168, 255 },
			material = "Neon",
			sound = "glass",
			hardness = 0.3,
			light = 15,
			lightColor = { 150, 200, 255 },
			drops = "GlowDust" :: string,
			dropCount = 4,
			lore = "A block of glowing dust: a bright, steady light.",
			formerly = { "Glowstone" },
		},
		{
			name = "Lantern",
			color = IRON,
			material = "Metal",
			sound = "metal",
			solid = false,
			placeable = true,
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			light = 15,
			lightColor = TORCH_LIGHT,
			shape = define.lantern(-8, false),
			bounds = { min = { 5, 0, 5 }, max = { 11, 9, 11 } },
			obstructs = true,
			support = "Down",
			behaviour = "Attached",
			lore = "A torch in iron: stands on the ground or hangs from a ceiling.",
			age = "iron",
		},
		{
			name = "HangingLantern",
			displayName = "Lantern",
			color = IRON,
			material = "Metal",
			sound = "metal",
			solid = false,
			placeable = false,
			hardness = 3.5,
			tool = "pickaxe",
			toolLevel = 0,
			light = 15,
			lightColor = TORCH_LIGHT,
			shape = define.lantern(-7, true),
			bounds = { min = { 5, 1, 5 }, max = { 11, 10, 11 } },
			obstructs = true,
			support = "Up",
			item = "Lantern",
			behaviour = "Attached",
		},
	})

	-- Glow lichen on each of the six faces, then its cave twins.
	for _, cave in { false, true } do
		for _, support in { "Down", "Up", "North", "South", "West", "East" } do
			local suffix = if support == "Down" then "" else support
			local twin = "GlowLichen" .. suffix
			local item = not cave and support == "Down"
			table.insert(list, {
				name = if cave then "CaveGlowLichen" .. suffix else twin,
				displayName = "Glow Lichen",
				color = LICHEN,
				material = "SmoothPlastic",
				sound = "grass",
				solid = false,
				replaceable = true,
				placeable = item,
				item = if item then nil else "GlowLichen",
				hardness = 0.2,
				tool = "axe",
				drops = "GlowDust" :: string,
				dropCount = 2,
				shearDrops = true,
				shearSpeed = 2,
				light = 7,
				lightColor = LICHEN_LIGHT,
				shape = shapes.lichenShape(support),
				bounds = shapes.lichenBounds(support),
				support = support,
				brokenByFluid = true,
				behaviour = "Attached",
				caveTwin = if cave then twin else nil,
				flammable = { ignite = 15, burn = 100 },
				-- (The item's; its picture covers the six and their twins.)
				texture = if item then { Front = "glow lichen" } else nil,
				lore = if item then "A faintly glowing cave growth. Gives Glow Dust." else nil,
			})
		end
	end
	return list
end
