--!strict
--[[
	The texture pack, like a Minecraft resource pack: every block texture in the game, which block
	face takes which, and the items' inventory icons. Pure data, built from the content packs
	(Shared/Content), so the server, the client, worker Actors and Lune all require it; Blocks
	resolves it into each block's `textures` (per face).

	  Textures  the packs' `textures` (each pack's for its blocks: the hand-edited sheets are the
	            Minecraft pack's textures/ and the Apocalypse pack's), texture name -> Texture
	  Blocks    block name -> Faces: each block entry's `texture`
	  Icons     item name -> its icon: each item entry's `icon`

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
	  `model`, in the item's voxel colours). Items whose icon is blank are drawn as models too, so
	  each look is one id to paste. Nothing to build: an image is shown as it is (no
	  MaterialVariant). Shared/Items checks every name and id when it loads.
]]

local Content = require(script.Parent.Content)
local Schema = require(script.Parent.Content.Schema)

-- (The types are Content/Schema's.)
export type Texture = Schema.Texture
export type Faces = Schema.Faces

local content = Content.default

-- Every texture: the packs'.
local Textures: { [string]: Texture } = content.textures

-- Block name -> the texture of each face: every block entry's `texture`.
local Blocks: { [string]: Faces } = {}
for _, spec in content.blocks do
	if spec.texture then
		Blocks[spec.name] = spec.texture
	end
end

-- Item name -> its inventory icon ("" = not made yet; see the header): every item entry's `icon`.
local Icons: { [string]: string } = {}
for _, spec in content.items do
	if spec.icon then
		Icons[spec.name] = spec.icon
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
