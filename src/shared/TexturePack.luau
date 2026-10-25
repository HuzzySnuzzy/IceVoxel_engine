--!strict
--[[
	The texture pack, like a Minecraft resource pack: every block texture in the game, which block
	face takes which, and the items' inventory icons. Pure data, built from the content packs
	(Shared/Content), so the server, the client, worker Actors and Lune all require it; Blocks
	resolves it into each block's `textures` (per face).

	  Textures  the packs' `textures` (each pack's for its blocks: the hand-edited sheets are the
	            Minecraft pack's textures/ and the Apocalypse pack's), texture name -> Texture
	  Blocks    block name -> Faces: each block entry's `texture`, and LEGACY_BLOCKS below for the
	            blocks whose entries name none yet (a block in both is an error)
	  Icons     item name -> its icon: each item entry's `icon`, and LEGACY_ICONS below (an item in
	            both is an error)

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
	  Paste its lines into the textures' entries (their packs' `textures`: Content/Packs/<pack>/
	  textures), so nothing has to be measured again. Until then distant chunks guess
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

local Content = require(script.Parent.Content)
local Schema = require(script.Parent.Content.Schema)

-- (The types are Content/Schema's.)
export type Texture = Schema.Texture
export type Faces = Schema.Faces

-- Block name -> the texture of each face: the side table, for blocks whose entries name no
-- `texture` yet (an entry's own goes into Blocks below, and naming both is an error).
local LEGACY_BLOCKS: { [string]: Faces } = {
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
	CoalBlock = { All = "coal block" },
	IronBlock = { All = "iron block" },
	GoldBlock = { All = "gold block" },
	DiamondBlock = { All = "diamond block" },
	EmeraldBlock = { All = "emerald block" },
	RawIronBlock = { All = "raw iron block" },
	RawGoldBlock = { All = "raw gold block" },

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
}

-- Item name -> its inventory icon ("" = not made yet; see the header): the side table, for
-- items whose entries have no `icon` yet (naming both is an error).
local LEGACY_ICONS: { [string]: string } = {}

local content = Content.default

-- Every texture: the packs'.
local Textures: { [string]: Texture } = content.textures

-- Every block's faces: its entry's, else the side table's.
local Blocks: { [string]: Faces } = table.clone(LEGACY_BLOCKS)
for _, spec in content.blocks do
	local texture = spec.texture
	if texture then
		assert(
			LEGACY_BLOCKS[spec.name] == nil,
			`TexturePack: {content.where("block", spec.name)} has its texture both on its entry and in LEGACY_BLOCKS`
		)
		Blocks[spec.name] = texture
	end
end

-- Every item's icon: its entry's, else the side table's.
local Icons: { [string]: string } = table.clone(LEGACY_ICONS)
for _, spec in content.items do
	local icon = spec.icon
	if icon then
		assert(
			LEGACY_ICONS[spec.name] == nil,
			`TexturePack: {content.where("item", spec.name)} has its icon both on its entry and in LEGACY_ICONS`
		)
		Icons[spec.name] = icon
	end
end

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
