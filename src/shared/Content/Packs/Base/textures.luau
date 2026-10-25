--!strict
--[[
	The Base pack's textures (TexturePack's Textures, moved here unchanged, but for the new ores',
	which are the Ores pack's): texture name (lower case, spaces, as Minecraft names them) ->
	Texture. Shared/TexturePack's header says how to fill one in and what each field does; blocks
	name them per face (their entries' `texture`, or TexturePack.Blocks).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
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
	-- The seasons' insulation (snow layers take "snow", above): wool-lined planks, double glass
	-- in iron, and the padded door's two halves (on its plate, as the other doors').
	["insulated planks"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["insulated glass"] = { Color = "", Material = "SmoothPlastic", Tint = false },
	["insulated door bottom"] = { Color = "", Material = "WoodPlanks", Tint = false },
	["insulated door top"] = { Color = "", Material = "WoodPlanks", Tint = false },
} :: { [string]: Schema.Texture }
