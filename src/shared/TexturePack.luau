--!strict
--[[
	The texture pack: every block texture in the game, in this one hand-edited module, like a
	Minecraft resource pack. Pure data that requires nothing, so the server, the client, worker
	Actors and Lune all require it; Blocks resolves it into each block's `textures` (per face).

	Filling an entry
	  Paste the *Image* asset id of a square image (512 x 512 px; one image covers one block face,
	  StudsPerTile studs) as "rbxassetid://<number>". Several textures may share one image (the
	  sheets do it on purpose: cracked and mossy bricks are the bricks' picture in their own
	  colours); each still gets its own entry, so it can be given a picture of its own later. A
	  Decal id (the number a Toolbox decal or a Decal's page shows) is a different number: Studio
	  converts one when you paste it into a property, but nothing converts it here, so it fails to
	  load (the game warns and draws the missing texture). Copy the id from Studio's Asset Manager
	  ("Copy Asset ID" on the image), or paste the Decal id into a Decal's Texture and copy the id
	  it turns into. Then run

	      lune run tests/build_textures

	  It writes src/textures/Materials.model.json (a MaterialVariant "IV_<name>" per filled
	  texture, spaces as "_", in MaterialService.IceVoxel) and src/textures/Images.model.json (a
	  Texture of the same name per filled texture, in ReplicatedStorage.IceVoxelTextures), and Rojo
	  (7.7.1, with its 7.7 Studio plugin) syncs them into Studio: save or publish the place so they
	  ship. Game scripts cannot make these themselves (their maps can only be set at edit time).
	  `--list` prints the blank textures and the blocks waiting on each (then the filled ones still
	  without an Average); `--check` fails when the files are out of date (the test suite checks
	  it too).

	Blank ids
	  Color = "" means "not made yet". While a block's sides and top are blank it keeps its plain
	  Roblox material and colour, as if it had no texture. A part takes one MaterialVariant on
	  every face, so once its sides' texture is filled in (or its top's, when the bottom has no
	  other) its blank faces show that one: the bark on a log's blank ends, the sandstone top on cut
	  sandstone's blank sides. A filled top that differs is drawn over its face as an image.
	  Normal, Roughness and Metalness may be "" or left out (none).

	Material
	  The Roblox material the MaterialVariant is based on (an Enum.Material name). Parts drawn with
	  the texture take this material, so pick the one closest to the picture (a block's sounds
	  stay its BlockList material's). Neon, Glass, ForceField, Air and Water cannot take a variant.

	Tint: how a texture takes the colour of the block it is drawn on
	  true    (the default) the drawn block's voxel colour (BlockList `color`): one texture shared
	          by every log, plank or leaf block, each in its own colour. With a known Average the
	          texture is scaled to average exactly that colour, otherwise the colour is multiplied
	          in.
	  false   the texture's own colours (ores and grass sides: the picture is the colour).
	  "Name"  that block's voxel colour, whatever block the texture is drawn on (the dirt under
	          grass is "Dirt" coloured, not grass coloured; the asphalt on a road line's sides is
	          "Asphalt" coloured, not the paint's).
	  A tint can only darken a part: its colour multiplies the texture and stops at 1. So a texture
	  shared by tinted blocks should be light, ideally greyscale, and at least as light as the
	  lightest block using it (birch logs are far lighter than spruce). Face images, plant sprites
	  and item cubes can also brighten. The game logs, once per block, a tint that had to stop at 1.

	Average
	  { r, g, b } 0-255: the colour map's average colour (the mean in linear light, written as
	  sRGB). The game tints with it, and colours distant chunks with it so they match the textured
	  ones near you. Leave it out and the game measures it (Config.Textures.MeasureAverages; needs
	  "Enable Mesh / Image APIs" in Game Settings > Security, and images the place's owner owns),
	  then prints to the output (F9 in game, or Studio's Output) a block starting
	      [IceVoxel] Texture averages (paste into TexturePack.Textures[...].Average):
	  Paste its lines here, so nothing has to be measured again. Until then distant chunks guess
	  those textures' colours each session, and the world is restyled once they are measured;
	  `lune run tests/build_textures --list` names the filled textures still without one.

	Align
	  false: a noise-like texture (leaves) that never needs Config.Textures.OddBoxes.

	Faces (Blocks)
	  All sets every face; Sides the four sides; Top and Bottom their own. A face given nothing
	  falls back to All, then to Sides. Front is for thin blocks on a face (glow lichen, ladders,
	  rails, vines): their plate's face looking away from what they hang on. Sprite is drawn as two
	  crossed images: plants, and the blocks Minecraft draws as a cross (rope, cobwebs, hanging
	  roots). An entry also covers the block's cave twin (which must look exactly like it, so
	  twins never get entries of their own) and the other blocks of its variant group (the six
	  glow lichen sides, the four ladders, both rails; a tall plant's top half unless it has its
	  own).

	ShowMissing
	  true draws the missing texture in place of blank textures, so you can see in game what is
	  left to make: on every face of a block whose sides are blank (unless its filled top stands in
	  for them, as above), on blank tops, and on blank plant sprites and glow lichen. A blank
	  bottom, or blank sides under a filled top, keep showing the block's texture (as above) unless
	  drawn as images of their own: bottoms with Config.Textures.BottomFaces, sides with
	  Config.Textures.SideImages.

	Never textured (no entries): fluids, air, cave air and structure voids, torches, lanterns and
	ceiling lamps, transmitters (pipes, cables, transporters), fluid tanks, machines and the solar
	panel, structure blocks and jigsaws, and the Glow Block (Neon cannot take a MaterialVariant).

	Icons (items that are no blocks)
	  Item name (ItemList) -> the *Image* asset id of its inventory picture (a square image, best
	  16 x 16 pixel art scaled up; transparent around the item), "rbxassetid://<number>", or "" for
	  not made yet. Inventories, the hotbar and JEI draw a filled icon instead of the item's model
	  (client Ui/ItemIcon); the hand, dropped items and characters keep drawing the model (ItemList
	  `model`, in the item's voxel colours). Items without an entry are drawn as models too: the
	  list holds the items made since icons came in (Terraria's), blank, so each look is one id to
	  paste. Nothing to build: an image is shown as it is (no MaterialVariant). Shared/Items checks
	  every name and id when it loads.
]]

export type Texture = {
	-- The colour map, "rbxassetid://<number>"; "" = not made yet.
	Color: string,
	-- Normal, roughness and metalness maps ("" or nil: none).
	Normal: string?,
	Roughness: string?,
	Metalness: string?,
	-- The Roblox material (Enum.Material name) the MaterialVariant is based on; parts using the
	-- texture take it.
	Material: string,
	-- true (default): the drawn block's voxel colour; false: the texture's own colours; a block
	-- name: that block's voxel colour.
	Tint: (boolean | string)?,
	-- { r, g, b } 0-255: the colour map's average (linear-light mean, as sRGB).
	Average: { number }?,
	-- false: never needs Config.Textures.OddBoxes (noisy textures: leaves).
	Align: boolean?,
}

export type Faces = {
	All: string?,
	Sides: string?,
	Top: string?,
	Bottom: string?,
	-- Glow lichen, ladders, rails, vines: the face looking away from its support.
	Front: string?,
	-- Plants, rope, cobwebs, hanging roots: drawn as two crossed images.
	Sprite: string?,
}

-- Texture name (lower case, spaces, as Minecraft names them) -> Texture.
local Textures: { [string]: Texture } = {
	-- The textures made so far (the sheet) ----------------------------------------------------------

	["dirt"] = {
		Color = "rbxassetid://124863036266976",
		Normal = "rbxassetid://72051511434165",
		Material = "Ground",
		Tint = "Dirt",
	},
	["grass top"] = {
		Color = "rbxassetid://108277463750403",
		Normal = "rbxassetid://99507506732683",
		Material = "Grass",
		Tint = true,
	},
	-- (Dirt with a green fringe, in its own colours.)
	["grass side"] = {
		Color = "rbxassetid://86851679897399",
		Normal = "rbxassetid://73522726802574",
		Material = "Ground",
		Tint = false,
	},
	["stone"] = {
		Color = "rbxassetid://140181032881606",
		Normal = "rbxassetid://99380706817425",
		Material = "Slate",
	},
	["cobblestone"] = {
		Color = "rbxassetid://75251272775135",
		Normal = "rbxassetid://84237009727338",
		Material = "Cobblestone",
	},
	["bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
	},
	["cracked stone bricks"] = {
		Color = "rbxassetid://102677558753560",
		Normal = "rbxassetid://121416480343872",
		Material = "Brick",
	},
	["sand"] = {
		Color = "rbxassetid://71309589762284",
		Normal = "rbxassetid://128379135184493",
		Material = "Sand",
	},
	["gravel"] = {
		Color = "rbxassetid://80041848472885",
		Normal = "rbxassetid://81186281605960",
		Material = "Pebble",
	},
	["snow"] = {
		Color = "rbxassetid://93188919600084",
		Normal = "rbxassetid://105336294076212",
		Material = "Snow",
	},
	["diorite"] = {
		Color = "rbxassetid://136661436562468",
		Normal = "rbxassetid://125518917530320",
		Material = "Limestone",
	},
	-- (The sheet gives calcite stone's normal map.)
	["calcite"] = {
		Color = "rbxassetid://127261168995224",
		Normal = "rbxassetid://99380706817425",
		Material = "Marble",
	},
	["obsidian"] = {
		Color = "rbxassetid://124134462736797",
		Normal = "rbxassetid://82694772111598",
		Material = "Basalt",
	},
	["ice"] = {
		Color = "rbxassetid://108401137755740",
		Material = "Glacier",
	},
	["packed ice"] = {
		Color = "rbxassetid://95721302530570",
		Material = "Ice",
	},
	--[[
		"Darker dirt" in the sheet: dirt's colour map, tinted with Packed Mud's own colour, which is
		darker than Dirt's in every channel (BlockList), so it shows darker than dirt (unless the
		image is darker still: a tint only darkens). The sheet's normal map repeated the colour
		map's id (a typo), so this uses dirt's normal map.
	]]
	["packed mud"] = {
		Color = "rbxassetid://124863036266976",
		Normal = "rbxassetid://72051511434165",
		Material = "Mud",
		Tint = true,
	},
	["coal ore"] = {
		Color = "rbxassetid://123190628695822",
		Normal = "rbxassetid://126178156614120",
		Material = "Rock",
		Tint = false,
	},
	["iron ore"] = {
		Color = "rbxassetid://105117991053609",
		Normal = "rbxassetid://78336303508336",
		Material = "Rock",
		Tint = false,
	},
	["gold ore"] = {
		Color = "rbxassetid://120488738320366",
		Normal = "rbxassetid://84056217279698",
		Material = "Rock",
		Tint = false,
	},
	["diamond ore"] = {
		Color = "rbxassetid://118816817484302",
		Normal = "rbxassetid://112898008799573",
		Material = "Rock",
		Tint = false,
	},
	-- (Every log's bark, in the log's own colour.)
	["log"] = {
		Color = "rbxassetid://120423551204729",
		Normal = "rbxassetid://109169967309613",
		Material = "Wood",
		Tint = true,
	},
	["planks"] = {
		Color = "rbxassetid://118497034160890",
		Normal = "rbxassetid://129159801834926",
		Material = "WoodPlanks",
		Tint = true,
	},
	-- (The sheet's normal map repeated the colour map's id, a typo, so leaves have none. Opaque, as
	-- Minecraft's "fast" leaves: nothing behind a leaf block is drawn.)
	["leaves"] = {
		Color = "rbxassetid://17327831454",
		Material = "LeafyGrass",
		Tint = true,
		Align = false,
	},
	["cactus side"] = {
		Color = "rbxassetid://108038569607208",
		Material = "Grass",
		Tint = true,
	},
	["cactus top"] = {
		Color = "rbxassetid://107644713378212",
		Material = "Grass",
		Tint = true,
	},
	["sandstone side"] = {
		Color = "rbxassetid://100157928191004",
		Normal = "rbxassetid://140637300323961",
		Material = "Sandstone",
	},
	["sandstone top"] = {
		Color = "rbxassetid://127212881957834",
		Normal = "rbxassetid://140637300323961",
		Material = "Sandstone",
	},
	["glow lichen"] = {
		Color = "rbxassetid://81026875222604",
		Material = "SmoothPlastic",
		Tint = false,
	},
	["short grass"] = {
		Color = "rbxassetid://113127329313443",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["tall grass bottom"] = {
		Color = "rbxassetid://100266742601250",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["tall grass top"] = {
		Color = "rbxassetid://104285260856645",
		Material = "SmoothPlastic",
		Tint = true,
	},

	-- The fourth sheet. It shares maps on purpose ("Ignore double id's this list is intentional"):
	-- andesite and cracked asphalt are one picture, polished andesite and asphalt another, all four
	-- on one normal map; the bricks' maps serve cracked and mossy bricks too.
	["andesite"] = {
		Color = "rbxassetid://135061946280047",
		Normal = "rbxassetid://84287333684009",
		Material = "Rock",
	},
	["polished andesite"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Concrete",
	},
	["smooth stone"] = {
		Color = "rbxassetid://126386401149504",
		Normal = "rbxassetid://92601327159349",
		Material = "Concrete",
	},
	["stone bricks"] = {
		Color = "rbxassetid://95612339340500",
		Normal = "rbxassetid://114812382647958",
		Material = "Brick",
	},
	-- (Its own picture, moss and all: its own colours, as Minecraft's.)
	["mossy cobblestone"] = {
		Color = "rbxassetid://136109631002116",
		Normal = "rbxassetid://97401111826072",
		Material = "Cobblestone",
		Tint = false,
	},
	-- ("All things moss": the moss block and the moss carpet, in the picture's own green, as
	-- Minecraft's moss is never tinted.)
	["moss block"] = {
		Color = "rbxassetid://133332486942553",
		Normal = "rbxassetid://80266253786825",
		Material = "Grass",
		Tint = false,
	},
	-- (On the vine's plate, tinted like the grass and leaves: the vine's own green, as Minecraft
	-- tints vines with the foliage colour. A plate's picture is a Decal, which takes no normal map;
	-- the sheet's is kept for the MaterialVariant all the same.)
	["vine"] = {
		Color = "rbxassetid://112502994131665",
		Normal = "rbxassetid://97312068579996",
		Material = "SmoothPlastic",
		Tint = true,
	},
	--[[
		The roads. Asphalt is drawn in Asphalt's own dark colour wherever it is ("Asphalt", as the
		dirt under grass is "Dirt"): on asphalt and on the sides and bottoms of the road lines,
		which stay dark beside the asphalt around them. The lines' tops are not on the sheet: they
		take asphalt's maps in the line's own colour (Tint true: white, yellow) until a painted
		line is made. Keep them filled: a blank top shows the sides' texture (the header), and the
		line would vanish into the asphalt. Cracked asphalt takes andesite's picture ("Yes uses
		andesite textures") in its own colour.
	]]
	["asphalt"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = "Asphalt",
	},
	["cracked asphalt"] = {
		Color = "rbxassetid://135061946280047",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	["road line"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	["road line yellow"] = {
		Color = "rbxassetid://70532405855463",
		Normal = "rbxassetid://84287333684009",
		Material = "Asphalt",
		Tint = true,
	},
	--[[
		Concrete, and the aged concrete and bricks. Cracked and mossy concrete are not on the sheet:
		they take concrete's maps, as the sheet itself does for cracked and mossy bricks ("Same
		texture for now, maybe darker tint", "maybe greener tint"). Each is tinted with its own
		voxel colour (BlockList): the cracked ones darker than the plain block in every channel,
		the mossy ones greener, so one picture reads as four blocks.
	]]
	["concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["cracked concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["mossy concrete"] = {
		Color = "rbxassetid://83707291495507",
		Normal = "rbxassetid://134665376447341",
		Material = "Concrete",
		Tint = true,
	},
	["cracked bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
		Tint = true,
	},
	["mossy bricks"] = {
		Color = "rbxassetid://78619102429227",
		Normal = "rbxassetid://126476239211015",
		Material = "Brick",
		Tint = true,
	},
	-- (The sheet's "crate" and "cabinet": one picture on every face, in its own colours.)
	["supply crate side"] = {
		Color = "rbxassetid://83206835598770",
		Normal = "rbxassetid://98971183237888",
		Material = "WoodPlanks",
		Tint = false,
	},
	["supply crate top"] = {
		Color = "rbxassetid://83206835598770",
		Normal = "rbxassetid://98971183237888",
		Material = "WoodPlanks",
		Tint = false,
	},
	["medicine cabinet side"] = {
		Color = "rbxassetid://125353153474912",
		Normal = "rbxassetid://97000542660093",
		Material = "Metal",
		Tint = false,
	},
	["medicine cabinet top"] = {
		Color = "rbxassetid://125353153474912",
		Normal = "rbxassetid://97000542660093",
		Material = "Metal",
		Tint = false,
	},

	-- The fallback (Missing below). The sheet does not know its size, and the id is an old, short
	-- one: check in Studio that it is an Image id, not a Decal id.
	["missing texture"] = {
		Color = "rbxassetid://925810526",
		Material = "SmoothPlastic",
		Tint = false,
	},

	-- Not made yet: fill these in (see the header) -----------------------------------------------

	["bedrock"] = { Color = "", Material = "Basalt" },
	["coarse dirt"] = { Color = "", Material = "Ground" },
	["podzol top"] = { Color = "", Material = "Ground" },
	["podzol side"] = { Color = "", Material = "Ground", Tint = false },
	["mycelium top"] = { Color = "", Material = "Grass" },
	["mycelium side"] = { Color = "", Material = "Ground", Tint = false },
	-- (Dirt with a dry, yellowed fringe, in its own colours: dry grass's sides. Until it is made,
	-- they keep the plain look in Dry Grass's colour, under the tinted grass top.)
	["dry grass side"] = { Color = "", Material = "Ground", Tint = false },
	["granite"] = { Color = "", Material = "Granite" },
	["polished diorite"] = { Color = "", Material = "Marble" },
	["polished granite"] = { Color = "", Material = "Concrete" },
	["emerald ore"] = { Color = "", Material = "Rock", Tint = false },
	["osmium ore"] = { Color = "", Material = "Granite", Tint = false },
	["coal block"] = { Color = "", Material = "Slate" },
	["iron block"] = { Color = "", Material = "Metal" },
	["gold block"] = { Color = "", Material = "Metal" },
	["diamond block"] = { Color = "", Material = "Metal" },
	["emerald block"] = { Color = "", Material = "Metal" },
	["raw iron block"] = { Color = "", Material = "Rock" },
	["raw gold block"] = { Color = "", Material = "Rock" },
	["osmium block"] = { Color = "", Material = "Metal" },
	["raw osmium block"] = { Color = "", Material = "Rock" },
	["blue ice"] = { Color = "", Material = "Ice" },
	["cut sandstone"] = { Color = "", Material = "Sandstone" },
	["sandstone bottom"] = { Color = "", Material = "Sandstone" },
	-- (Every log's end rings, in the log's own colour.)
	["log top"] = { Color = "", Material = "Wood", Tint = true },
	-- (Glass cannot take a MaterialVariant: textured glass is SmoothPlastic, as see-through as the
	-- block.)
	["glass"] = { Color = "", Material = "SmoothPlastic" },
	-- (The chest, crafting table and furnace keep their decorated faces drawn over these.)
	["chest"] = { Color = "", Material = "WoodPlanks" },
	["crafting table top"] = { Color = "", Material = "WoodPlanks" },
	["crafting table side"] = { Color = "", Material = "WoodPlanks" },
	["furnace top"] = { Color = "", Material = "Cobblestone" },
	["furnace side"] = { Color = "", Material = "Cobblestone" },
	-- (TNT and the Nuke keep their decorated faces too; lit, they share their unlit textures.)
	["tnt side"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["tnt top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["tnt bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["nuke side"] = { Color = "", Material = "Metal", Tint = false },
	["nuke top"] = { Color = "", Material = "Metal", Tint = false },
	-- Plant sprites. Grass and ferns take their soil's foliage colour (Tint = true); flowers,
	-- dead bushes and mushrooms keep the picture's colours.
	["fern"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["large fern bottom"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["large fern top"] = { Color = "", Material = "SmoothPlastic", Tint = true },
	["dead bush"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["dandelion"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["poppy"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["blue orchid"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["allium"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["azure bluet"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["red tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["orange tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["white tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["pink tulip"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["oxeye daisy"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["cornflower"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lily of the valley"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["sunflower bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["sunflower top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lilac bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["lilac top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rose bush bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rose bush top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["peony bottom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["peony top"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["brown mushroom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	-- (One black and white picture for every sapling, tinted with each one's colour.)
	["sapling"] = {
		Color = "rbxassetid://127390623075923",
		Material = "SmoothPlastic",
		Tint = true,
	},
	["red mushroom"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	-- (The herbs: Tough As Nails' mint and wild ginger.)
	["mint"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["wild ginger"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	-- (Sheep's wool: white, Shared/Entities/MobList.)
	["white wool"] = { Color = "", Material = "Fabric", Tint = false },
	-- Ladders, rope and the mineshafts' blocks. The ladder and rail pictures are drawn on the
	-- block's plate (Front: Minecraft's single quad, see-through around the rails and rungs), as
	-- the vine's is, the rope, cobweb and hanging roots pictures as sprites (two crossed planes,
	-- Minecraft's chain and cross models); the fence post takes "planks" and the moss carpet
	-- "moss block" (both made, above), as their Minecraft models do.
	["ladder"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["rope"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["rail"] = { Color = "", Material = "Metal", Tint = false },
	["cobweb"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["hanging roots"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	-- Doors: Minecraft's door pictures, the lower and upper half's, drawn on both sides of the
	-- door's plate in place of its boxes (see-through where the picture is: the windows). The same
	-- picture serves both hinges. Fill an item's icon (Icons below) with the whole door too.
	["oak door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["oak door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["spruce door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["spruce door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["birch door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["birch door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["jungle door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["jungle door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["acacia door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["acacia door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
	-- The zombie apocalypse's ruins and bunkers still waiting (the roads, concrete, aged bricks,
	-- the supply crate and the medicine cabinet are made, above): the wrecks' rusty steel and the
	-- bunker hatch. Barricades take "planks" and the ceiling lamp none (a light).
	["rusty metal"] = { Color = "", Material = "CorrodedMetal", Tint = false },
	["bunker hatch"] = { Color = "", Material = "DiamondPlate", Tint = false },
}

-- Block name (BlockList) -> the texture of each face.
local Blocks: { [string]: Faces } = {
	-- Ground
	Bedrock = { All = "bedrock" },
	Stone = { All = "stone" },
	Cobblestone = { All = "cobblestone" },
	Dirt = { All = "dirt" },
	CoarseDirt = { All = "coarse dirt" },
	Grass = { Top = "grass top", Sides = "grass side", Bottom = "dirt" },
	-- (The same grass top in DryGrass's own colour; sides of its own, not the green fringe.)
	DryGrass = { Top = "grass top", Sides = "dry grass side", Bottom = "dirt" },
	Podzol = { Top = "podzol top", Sides = "podzol side", Bottom = "dirt" },
	Mycelium = { Top = "mycelium top", Sides = "mycelium side", Bottom = "dirt" },
	PackedMud = { All = "packed mud" },
	Gravel = { All = "gravel" },
	Sand = { All = "sand" },
	Snow = { All = "snow" },
	Ice = { All = "ice" },
	PackedIce = { All = "packed ice" },
	BlueIce = { All = "blue ice" },
	Obsidian = { All = "obsidian" },

	-- Stones
	Andesite = { All = "andesite" },
	Diorite = { All = "diorite" },
	Granite = { All = "granite" },
	Calcite = { All = "calcite" },
	PolishedAndesite = { All = "polished andesite" },
	PolishedDiorite = { All = "polished diorite" },
	PolishedGranite = { All = "polished granite" },
	SmoothStone = { All = "smooth stone" },
	StoneBricks = { All = "stone bricks" },
	CrackedStoneBricks = { All = "cracked stone bricks" },
	Brick = { All = "bricks" },
	Sandstone = { Top = "sandstone top", Sides = "sandstone side", Bottom = "sandstone bottom" },
	CutSandstone = { Top = "sandstone top", Sides = "cut sandstone" },
	-- (Minecraft's smooth sandstone is the sandstone top on every face.)
	SmoothSandstone = { All = "sandstone top" },

	-- Ores and their blocks
	CoalOre = { All = "coal ore" },
	IronOre = { All = "iron ore" },
	GoldOre = { All = "gold ore" },
	DiamondOre = { All = "diamond ore" },
	EmeraldOre = { All = "emerald ore" },
	OsmiumOre = { All = "osmium ore" },
	CoalBlock = { All = "coal block" },
	IronBlock = { All = "iron block" },
	GoldBlock = { All = "gold block" },
	DiamondBlock = { All = "diamond block" },
	EmeraldBlock = { All = "emerald block" },
	RawIronBlock = { All = "raw iron block" },
	RawGoldBlock = { All = "raw gold block" },
	OsmiumBlock = { All = "osmium block" },
	RawOsmiumBlock = { All = "raw osmium block" },

	-- Trees
	OakLog = { Sides = "log", Top = "log top", Bottom = "log top" },
	BirchLog = { Sides = "log", Top = "log top", Bottom = "log top" },
	SpruceLog = { Sides = "log", Top = "log top", Bottom = "log top" },
	AcaciaLog = { Sides = "log", Top = "log top", Bottom = "log top" },
	JungleLog = { Sides = "log", Top = "log top", Bottom = "log top" },
	OakLeaves = { All = "leaves" },
	BirchLeaves = { All = "leaves" },
	SpruceLeaves = { All = "leaves" },
	AcaciaLeaves = { All = "leaves" },
	JungleLeaves = { All = "leaves" },
	Planks = { All = "planks" },
	BirchPlanks = { All = "planks" },
	SprucePlanks = { All = "planks" },
	AcaciaPlanks = { All = "planks" },
	JunglePlanks = { All = "planks" },
	Cactus = { Sides = "cactus side", Top = "cactus top", Bottom = "cactus top" },

	-- Made blocks
	Glass = { All = "glass" },
	Chest = { All = "chest" },
	-- (Minecraft's crafting table bottom is oak planks: Bottom = "planks" gives it them, in the
	-- crafting table's colour; a bottom shows near you only with Config.Textures.BottomFaces.)
	CraftingTable = { Top = "crafting table top", Sides = "crafting table side" },
	Furnace = { Top = "furnace top", Sides = "furnace side", Bottom = "furnace top" },
	Tnt = { Top = "tnt top", Sides = "tnt side", Bottom = "tnt bottom" },
	Nuke = { Top = "nuke top", Sides = "nuke side", Bottom = "nuke top" },

	-- Glow lichen (all six sides, and their cave twins)
	GlowLichen = { Front = "glow lichen" },

	-- Plants
	ShortGrass = { Sprite = "short grass" },
	Fern = { Sprite = "fern" },
	TallGrass = { Sprite = "tall grass bottom" },
	TallGrassTop = { Sprite = "tall grass top" },
	LargeFern = { Sprite = "large fern bottom" },
	LargeFernTop = { Sprite = "large fern top" },
	DeadBush = { Sprite = "dead bush" },
	Dandelion = { Sprite = "dandelion" },
	Poppy = { Sprite = "poppy" },
	BlueOrchid = { Sprite = "blue orchid" },
	Allium = { Sprite = "allium" },
	AzureBluet = { Sprite = "azure bluet" },
	RedTulip = { Sprite = "red tulip" },
	OrangeTulip = { Sprite = "orange tulip" },
	WhiteTulip = { Sprite = "white tulip" },
	PinkTulip = { Sprite = "pink tulip" },
	OxeyeDaisy = { Sprite = "oxeye daisy" },
	Cornflower = { Sprite = "cornflower" },
	LilyOfTheValley = { Sprite = "lily of the valley" },
	Sunflower = { Sprite = "sunflower bottom" },
	SunflowerTop = { Sprite = "sunflower top" },
	Lilac = { Sprite = "lilac bottom" },
	LilacTop = { Sprite = "lilac top" },
	RoseBush = { Sprite = "rose bush bottom" },
	RoseBushTop = { Sprite = "rose bush top" },
	Peony = { Sprite = "peony bottom" },
	PeonyTop = { Sprite = "peony top" },
	BrownMushroom = { Sprite = "brown mushroom" },
	OakSapling = { Sprite = "sapling" },
	BirchSapling = { Sprite = "sapling" },
	SpruceSapling = { Sprite = "sapling" },
	AcaciaSapling = { Sprite = "sapling" },
	JungleSapling = { Sprite = "sapling" },
	RedMushroom = { Sprite = "red mushroom" },
	Mint = { Sprite = "mint" },
	WildGinger = { Sprite = "wild ginger" },

	-- Wool
	WhiteWool = { All = "white wool" },

	-- Ladders, rope and the mineshafts' blocks (an entry covers a variant group: the four ladders,
	-- both rails, the four vines; and every cave twin)
	Ladder = { Front = "ladder" },
	Rope = { Sprite = "rope" },
	Rail = { Front = "rail" },
	OakFence = { All = "planks" },
	Cobweb = { Sprite = "cobweb" },
	MossBlock = { All = "moss block" },
	MossCarpet = { All = "moss block" },
	Vine = { Front = "vine" },
	HangingRoots = { Sprite = "hanging roots" },
	MossyCobblestone = { All = "mossy cobblestone" },

	-- Doors (an entry covers the door's lower halves; the ...Top entry its upper halves:
	-- Blocks' door rule)
	OakDoor = { Front = "oak door bottom" },
	OakDoorTop = { Front = "oak door top" },
	SpruceDoor = { Front = "spruce door bottom" },
	SpruceDoorTop = { Front = "spruce door top" },
	BirchDoor = { Front = "birch door bottom" },
	BirchDoorTop = { Front = "birch door top" },
	JungleDoor = { Front = "jungle door bottom" },
	JungleDoorTop = { Front = "jungle door top" },
	AcaciaDoor = { Front = "acacia door bottom" },
	AcaciaDoorTop = { Front = "acacia door top" },

	-- The zombie apocalypse (an entry covers a variant group: both barricades of a kind, both
	-- bunker hatches)
	Asphalt = { All = "asphalt" },
	CrackedAsphalt = { All = "cracked asphalt" },
	RoadLine = { Top = "road line", Sides = "asphalt", Bottom = "asphalt" },
	RoadLineYellow = { Top = "road line yellow", Sides = "asphalt", Bottom = "asphalt" },
	Concrete = { All = "concrete" },
	CrackedConcrete = { All = "cracked concrete" },
	MossyConcrete = { All = "mossy concrete" },
	CrackedBricks = { All = "cracked bricks" },
	MossyBricks = { All = "mossy bricks" },
	RustyMetal = { All = "rusty metal" },
	SupplyCrate = { Top = "supply crate top", Sides = "supply crate side", Bottom = "supply crate top" },
	MedicineCabinet = { Top = "medicine cabinet top", Sides = "medicine cabinet side" },
	Barricade = { All = "planks" },
	ReinforcedBarricade = { All = "planks" },
	BunkerHatch = { All = "bunker hatch" },
}

-- Item name (ItemList) -> its inventory icon ("" = not made yet; see the header).
local Icons: { [string]: string } = {
	-- Terraria's accessories.
	HermesBoots = "",
	CloudInABottle = "",
	ShinyRedBalloon = "",
	LuckyHorseshoe = "",
	Aglet = "",
	AnkletOfTheWind = "",
	BandOfRegeneration = "",
	BandOfStarpower = "",
	ObsidianSkull = "",
	Flipper = "",
	CobaltShield = "",
	FeralClaws = "",
	-- Mana.
	FallenStar = "",
	ManaCrystal = "",
	LesserManaPotion = "",
	ManaPotion = "",
	-- Magic weapons.
	WandOfSparking = "",
	EmeraldStaff = "",
	WaterBolt = "",
	-- Vanity clothes.
	TopHat = "",
	TuxedoShirt = "",
	TuxedoPants = "",
	-- The zombie apocalypse's medical supplies, materials, food and drink, and weapons.
	Bandage = "",
	Medkit = "",
	Antibiotics = "",
	Painkillers = "",
	Rag = "",
	DuctTape = "",
	Nails = "",
	ScrapMetal = "",
	CannedBeans = "",
	CannedPeaches = "",
	Crackers = "",
	ChocolateBar = "",
	MilitaryRation = "",
	BottledWater = "",
	SodaCan = "",
	BaseballBat = "",
	SpikedBat = "",
	Machete = "",
	Crowbar = "",
	FireAxe = "",
	HerbalPoultice = "",
	-- The weapons (Shared/Weapons): firearms, magazines, ammunition, attachments, melee.
	Pistol = "",
	Revolver = "",
	Smg = "",
	PumpShotgun = "",
	DoubleBarrelShotgun = "",
	BoltActionRifle = "",
	SemiAutoRifle = "",
	AssaultRifle = "",
	HuntingRifle = "",
	SmallBoreRifle = "",
	Crossbow = "",
	PistolMagazine = "",
	SmgMagazine = "",
	RifleMagazine = "",
	HuntingMagazine = "",
	SmallBoreMagazine = "",
	Rounds9mm = "",
	Rounds357 = "",
	Buckshot = "",
	Slugs = "",
	Rounds22 = "",
	Rounds556 = "",
	Rounds762 = "",
	Rounds308 = "",
	CrossbowBolt = "",
	RedDotSight = "",
	RifleScope = "",
	Suppressor = "",
	ImprovisedSuppressor = "",
	WeaponFlashlight = "",
	KitchenKnife = "",
	HuntingKnife = "",
	PipeWrench = "",
	Sledgehammer = "",
}

export type Pack = {
	StudsPerTile: number,
	ShowMissing: boolean,
	Missing: string,
	Textures: { [string]: Texture },
	Blocks: { [string]: Faces },
	Icons: { [string]: string },
}

local pack: Pack = {
	-- Studs one tile covers: one image per block face (Config.BlockSize).
	StudsPerTile = 3,
	-- true: draw the missing texture in place of blank textures (see the header).
	ShowMissing = false,
	-- The texture drawn where one is missing (ShowMissing, or an id that failed to load).
	Missing = "missing texture",
	Textures = Textures,
	Blocks = Blocks,
	Icons = Icons,
}

return pack
